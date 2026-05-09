import Foundation
import Combine
import SwiftUI
import GhosttyKit

// Bonsplit is vendored in macos/Sources/Bonsplit — same target, no import.

extension Notification.Name {
    /// Posted by `Ghostty.SurfaceView.focusDidChange(_:)` whenever the real
    /// AppKit terminal surface gains or loses first-responder focus.
    static let ghosttySurfaceFocusDidChange = Notification.Name("BOOGhosttySurfaceFocusDidChange")
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil
            ? defaultValue
            : bool(forKey: key)
    }
}

/// Per-window Boo state. Owns the Bonsplit controller, the surfaces hosted by
/// its tabs, and the notification subscriptions that translate ghostty action
/// callbacks into Bonsplit operations.
///
/// Multiple Boo windows can coexist: each `BooState` filters incoming
/// notifications by whether the originating surface belongs to its own
/// surface map, so windows don't steal each other's events.
@MainActor
final class BooState: ObservableObject {
    /// The shared ghostty runtime. Required to spawn surfaces.
    let ghostty: Ghostty.App

    @Published private(set) var workspaces: [BooWorkspace] = []
    @Published private(set) var activeWorkspaceId: WorkspaceID?

    var controller: BonsplitController {
        guard let workspace = activeWorkspace else {
            preconditionFailure("BooState has no active workspace")
        }
        return workspace.controller
    }

    private var activeWorkspace: BooWorkspace? {
        guard let activeWorkspaceId else { return nil }
        return workspaces.first { $0.id == activeWorkspaceId }
    }

    /// Owning window, set by `BooController` after init. Used to decide which
    /// state handles app-level (non-surface-scoped) notifications like
    /// "new tab from ⌘T with no focused surface".
    weak var window: NSWindow?

    /// One ghostty surface per Bonsplit tab. Owned here so the surface
    /// outlives any individual SwiftUI render — `Ghostty.SurfaceView` is a
    /// heavy NSView with a live PTY + child process.
    @Published var surfaces: [TabID: Ghostty.SurfaceView] = [:]

    /// Combine subscriptions that forward each surface's `$title`/`$pwd`
    /// into the Bonsplit tab title and (when this is the focused tab) into
    /// the hosting window's title + proxy icon. Keyed by tab id; cancelled
    /// when the tab closes.
    private var surfaceSubscriptions: [TabID: Set<AnyCancellable>] = [:]

    /// Tab currently mirrored into the window chrome (window title + proxy
    /// icon). Set by `updateWindowChromeTabId()` on focus/selection changes.
    private var windowChromeTabId: TabID?

    /// Public mirror of the window chrome for Boo's custom titlebar accessory.
    @Published private(set) var windowChromeTitle: String = "Boo"
    @Published private(set) var windowChromeURL: URL?

    /// The most recently focused terminal surface owned by this Boo window.
    ///
    /// We use this as the explicit `from:` argument when UI actions (tab-bar
    /// split buttons, tab selection, tab drag/drop) move focus without first
    /// generating a surface click. AppKit sometimes fails to make the old
    /// surface fully resign first responder in those paths unless we name the
    /// source surface explicitly.
    private weak var focusedOwnedSurface: Ghostty.SurfaceView?

    /// Public access to the focused surface for menu actions.
    var focusedSurface: Ghostty.SurfaceView? { focusedOwnedSurface }

    /// Guard to prevent re-entrant focus changes. When true, focus-related
    /// callbacks are suppressed to avoid oscillation loops.
    @Published private(set) var isChangingFocus = false

    /// Terminal background color from config, updated on config reload.
    /// Used by the tab bar to match the window background.
    @Published private(set) var terminalBackgroundColor: Color

    /// Whether this window is currently the key window.
    @Published private(set) var isWindowKey: Bool = true

    /// Whether the per-window workspace selector is visible.
    ///
    /// Hidden by default so the configured window size maps to the terminal
    /// surface size on initial render. Showing the sidebar later intentionally
    /// narrows the terminal surface within the existing window.
    @Published private(set) var isWorkspaceSidebarVisible: Bool = false

    /// Workspaces whose SwiftUI/AppKit view trees should remain mounted.
    ///
    /// PTYs and SurfaceViews stay alive for every workspace, but mounting every
    /// BonsplitView forever can waste layout/compositing work. We keep a warm
    /// set mounted so common switches and close fallbacks can focus an already
    /// attached SurfaceView synchronously while cold workspaces are unmounted.
    @Published private(set) var mountedWorkspaceIds: Set<WorkspaceID> = []

    private let recentMountedWorkspaceLimit = 2
    private var recentlyActiveWorkspaceIds: [WorkspaceID] = []
    private var pendingWorkspaceActivationId: WorkspaceID?

    /// Flag to skip auto-focus during tab drag-out operations.
    private var isDraggingTabOut: Bool = false

    /// Tabs whose close was just confirmed by the user. When `shouldCloseTab`
    /// sees an id here, it pops it out and allows the close through without
    /// re-asking. Used to bounce through Bonsplit's close flow a second time
    /// after the user OKs the confirmation alert.
    private var confirmedCloseTabIds: Set<TabID> = []

    /// Panes whose close was just confirmed by the user. Mirrors
    /// `confirmedCloseTabIds` for `shouldClosePane`.
    private var confirmedClosePaneIds: Set<PaneID> = []

    /// Whether a close confirmation alert is currently on screen. Blocks
    /// issuing a second alert for a concurrent close attempt (e.g. holding
    /// ⌘W or clicking multiple X buttons).
    private var isShowingCloseConfirmation = false

    private var tabCounter = 0

    /// True while Boo itself is synchronously creating a Bonsplit tab and
    /// will attach the corresponding SurfaceView immediately after
    /// `createTab` returns. Bonsplit fires `didCreateTab` inside `createTab`,
    /// so without this guard the delegate fallback creates a duplicate
    /// SurfaceView that is then immediately released, leaving libghostty with
    /// a stale unretained userdata pointer.
    private var isCreatingBooManagedTab = false

    init(ghostty: Ghostty.App, baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        self.ghostty = ghostty
        self.terminalBackgroundColor = ghostty.config.backgroundColor

        subscribeToGhosttyNotifications()

        // Seed one initial workspace/tab so the window isn't empty on open.
        let workspaceId = createWorkspace(baseConfig: baseConfig)
        activateWorkspace(.init(id: workspaceId, reason: .initialWindow))
    }

    /// Init with an existing surface (for drag-out-to-new-window).
    init(ghostty: Ghostty.App, existingSurface: Ghostty.SurfaceView) {
        self.ghostty = ghostty
        self.terminalBackgroundColor = ghostty.config.backgroundColor

        subscribeToGhosttyNotifications()

        // Adopt the existing surface into the initial workspace instead of
        // creating a new one.
        let workspaceId = createWorkspace(existingSurface: existingSurface)
        activateWorkspace(.init(id: workspaceId, reason: .initialWindow))
    }

    private func makeWorkspaceController() -> BonsplitController {
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            contentViewLifecycle: .keepAllAlive
        )
        let controller = BonsplitController(configuration: config)
        controller.delegate = self
        setupTabDragOutCallback(for: controller)
        return controller
    }

    /// Set up callback for when a tab is dragged outside all windows.
    private func setupTabDragOutCallback(for controller: BonsplitController) {
        controller.onTabDragEndedOutside = { [weak self] tab, _, screenPoint in
            self?.handleTabDraggedOutside(tab: tab, at: screenPoint)
        }
    }

    /// Handle a tab being dragged outside all windows - create a new window.
    private func handleTabDraggedOutside(tab: Tab, at screenPoint: NSPoint?) {
        // Get the surface for this tab
        guard let surface = surfaces[tab.id] else { return }

        guard let sourceController = controllerContaining(tabId: tab.id) else { return }

        // Only drag out if there's more than one tab/split total in this workspace.
        let totalTabs = sourceController.allPaneIds.reduce(0) { $0 + sourceController.tabs(inPane: $1).count }
        guard totalTabs > 1 else { return }

        // Set flag to skip auto-focus in didCloseTab
        isDraggingTabOut = true
        defer { isDraggingTabOut = false }

        // Clear focusedOwnedSurface if it was the dragged surface
        if focusedOwnedSurface === surface {
            focusedOwnedSurface = nil
        }

        // Remove from our tracking
        surfaces.removeValue(forKey: tab.id)
        surfaceSubscriptions.removeValue(forKey: tab.id)
        sourceController.closeTab(tab.id)

        // Unfocus all surfaces in this window
        unfocusAllSurfaces()

        // Create new window with the dragged surface
        _ = BooController.newWindow(ghostty, withSurface: surface, position: screenPoint)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Workspace ops

    private enum WorkspaceActivationReason {
        /// Initial state seeding. The window activation callback will move focus
        /// once SwiftUI/AppKit hosting exists.
        case initialWindow

        /// User explicitly switched workspaces via sidebar or keyboard shortcut.
        case userSwitch

        /// User created a new workspace and expects it to become active.
        case createNew

        /// The active workspace was removed and Boo selected a replacement.
        case closeFallback

        /// A Ghostty surface-scoped action requires making the source
        /// workspace active, but the action itself will handle any focus move.
        case surfaceAction

        var shouldFocus: Bool {
            switch self {
            case .initialWindow, .surfaceAction:
                return false
            case .userSwitch, .createNew, .closeFallback:
                return true
            }
        }
    }

    private struct WorkspaceActivation {
        let id: WorkspaceID
        let reason: WorkspaceActivationReason
    }

    @discardableResult
    func newWorkspace(
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        existingSurface: Ghostty.SurfaceView? = nil
    ) -> WorkspaceID {
        let workspaceId = createWorkspace(
            baseConfig: baseConfig,
            existingSurface: existingSurface
        )
        activateWorkspace(.init(id: workspaceId, reason: .createNew))
        return workspaceId
    }

    private func createWorkspace(
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        existingSurface: Ghostty.SurfaceView? = nil
    ) -> WorkspaceID {
        let workspace = BooWorkspace(
            controller: makeWorkspaceController(),
            title: "Boo"
        )
        workspaces.append(workspace)

        // Establish an active workspace before creating the first tab/surface
        // so lower-level helpers that update window chrome can resolve the
        // current Bonsplit controller. Activation still owns focus.
        if activeWorkspaceId == nil {
            activeWorkspaceId = workspace.id
            refreshMountedWorkspaces(keeping: [workspace.id])
        }

        if let existingSurface {
            adoptSurface(existingSurface, in: workspace.controller, focusAfterCreate: false)
        } else {
            newTab(in: workspace.controller, baseConfig: baseConfig, focusAfterCreate: false)
        }

        updateWindowChromeTabId()
        return workspace.id
    }

    func switchToWorkspace(_ id: WorkspaceID) {
        activateWorkspace(.init(id: id, reason: .userSwitch))
    }

    func switchToWorkspace(at index: Int) {
        guard !workspaces.isEmpty else { return }
        let clampedIndex = min(max(index, 0), workspaces.count - 1)
        activateWorkspace(.init(id: workspaces[clampedIndex].id, reason: .userSwitch))
    }

    func isWorkspaceMounted(_ id: WorkspaceID) -> Bool {
        mountedWorkspaceIds.contains(id)
    }

    func workspaceDisplayTitle(_ workspace: BooWorkspace) -> String {
        if let customTitle = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customTitle.isEmpty {
            return customTitle
        }

        if let tabId = selectedTabId(in: workspace),
           let title = surfaces[tabId]?.title.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }

        return "Boo"
    }

    func renameWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Workspace"
        alert.informativeText = "Enter a custom workspace title."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(string: workspaceDisplayTitle(workspace))
        textField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = textField

        let applyRename = { [weak self, weak textField] in
            guard let self, let textField else { return }
            let title = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.objectWillChange.send()
            workspace.customTitle = title.isEmpty ? nil : title
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    applyRename()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            applyRename()
        }
    }

    func closeWorkspace(_ id: WorkspaceID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }

        if workspaces.count == 1 {
            window?.performClose(nil)
            return
        }

        let workspaceSurfaces = workspace.controller.allTabIds.compactMap { surfaces[$0] }
        let close = { [weak self] in
            guard let self else { return }
            self.performCloseWorkspace(id)
        }

        guard workspaceSurfaces.contains(where: { $0.needsConfirmQuit }) else {
            close()
            return
        }

        presentCloseConfirmation(
            messageText: "Close Workspace?",
            informativeText: "A terminal in this workspace still has a running process. If you close the workspace the process will be killed.",
            onConfirm: close
        )
    }

    func toggleWorkspaceSidebar() {
        isWorkspaceSidebarVisible.toggle()
    }

    private func activateWorkspace(_ activation: WorkspaceActivation) {
        guard workspaces.contains(where: { $0.id == activation.id }) else { return }

        let canActivateNow = activeWorkspaceId == activation.id
            || mountedWorkspaceIds.contains(activation.id)
            || !activation.reason.shouldFocus

        if canActivateNow {
            pendingWorkspaceActivationId = nil
            applyWorkspaceActivation(activation)
            return
        }

        // Cold workspace: mount it hidden for one render pass, then make it
        // active. This keeps arbitrary workspace switches and repeated
        // Command-N creation from racing AppKit attachment while avoiding
        // permanently mounted cold workspaces.
        pendingWorkspaceActivationId = activation.id
        refreshMountedWorkspaces(keeping: [activation.id])
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingWorkspaceActivationId == activation.id else { return }
            self.pendingWorkspaceActivationId = nil
            self.applyWorkspaceActivation(activation)
        }
    }

    private func applyWorkspaceActivation(_ activation: WorkspaceActivation) {
        guard workspaces.contains(where: { $0.id == activation.id }) else { return }

        if activeWorkspaceId != activation.id {
            if let activeWorkspaceId {
                recentlyActiveWorkspaceIds.removeAll { $0 == activeWorkspaceId }
                recentlyActiveWorkspaceIds.insert(activeWorkspaceId, at: 0)
            }

            unfocusAllSurfaces()
            focusedOwnedSurface = nil
            activeWorkspaceId = activation.id
        }

        refreshMountedWorkspaces()
        updateWindowChromeTabId()

        if activation.reason.shouldFocus {
            // Warm workspaces stay mounted in BooRootView, so common switches
            // and close fallbacks can move AppKit first-responder focus
            // immediately instead of waiting for SwiftUI to build the view.
            focusCurrentTabSurface(reason: .workspaceActivated, immediately: true)
        }
    }

    private func refreshMountedWorkspaces(keeping extraIds: Set<WorkspaceID> = []) {
        let ids = workspaces.map(\.id)
        let validIds = Set(ids)
        recentlyActiveWorkspaceIds = recentlyActiveWorkspaceIds.filter { validIds.contains($0) }
        if let pendingWorkspaceActivationId, !validIds.contains(pendingWorkspaceActivationId) {
            self.pendingWorkspaceActivationId = nil
        }

        var mounted = extraIds.intersection(validIds)
        if let pendingWorkspaceActivationId, validIds.contains(pendingWorkspaceActivationId) {
            mounted.insert(pendingWorkspaceActivationId)
        }

        if let activeWorkspaceId,
           let activeIndex = ids.firstIndex(of: activeWorkspaceId) {
            mounted.insert(activeWorkspaceId)

            if activeIndex > ids.startIndex {
                mounted.insert(ids[ids.index(before: activeIndex)])
            }
            let nextIndex = ids.index(after: activeIndex)
            if nextIndex < ids.endIndex {
                mounted.insert(ids[nextIndex])
            }
        }

        for id in recentlyActiveWorkspaceIds.prefix(recentMountedWorkspaceLimit) {
            mounted.insert(id)
        }

        mountedWorkspaceIds = mounted
    }

    private func removeWorkspace(for controller: BonsplitController) {
        guard workspaces.count > 1,
              let index = workspaces.firstIndex(where: { $0.controller === controller }) else { return }

        let removed = workspaces.remove(at: index)
        if activeWorkspaceId == removed.id {
            let newIndex = min(index, workspaces.count - 1)
            activateWorkspace(.init(id: workspaces[newIndex].id, reason: .closeFallback))
        } else {
            refreshMountedWorkspaces()
        }
    }

    private func performCloseWorkspace(_ id: WorkspaceID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let removed = workspaces[index]

        for tabId in removed.controller.allTabIds {
            if let surface = surfaces[tabId] {
                surface.cachedScrollView = nil
            }
            surfaces.removeValue(forKey: tabId)
            surfaceSubscriptions.removeValue(forKey: tabId)
        }

        workspaces.remove(at: index)

        if activeWorkspaceId == removed.id {
            let newIndex = min(index, workspaces.count - 1)
            activateWorkspace(.init(id: workspaces[newIndex].id, reason: .closeFallback))
        } else {
            refreshMountedWorkspaces()
            updateWindowChromeTabId()
        }
    }

    // MARK: - Tab ops

    private enum SurfaceSource {
        case create(config: Ghostty.SurfaceConfiguration?)
        case adopt(Ghostty.SurfaceView)

        var initialTitle: String {
            switch self {
            case .create:
                return "👻"
            case .adopt(let surface):
                return surface.title.isEmpty ? "👻" : surface.title
            }
        }
    }

    private struct CreatedSurfaceTab {
        let tabId: TabID
        let surface: Ghostty.SurfaceView
        let controller: BonsplitController
    }

    /// Create a new Bonsplit tab and spawn a fresh ghostty surface into it.
    /// If `paneId` is nil, the tab goes to Bonsplit's focused pane.
    /// If `focusAfterCreate` is false, focus is not moved to the new surface.
    @discardableResult
    func newTab(
        inPane paneId: PaneID? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        focusAfterCreate: Bool = true
    ) -> TabID? {
        newTab(
            in: controller,
            inPane: paneId,
            baseConfig: baseConfig,
            focusAfterCreate: focusAfterCreate
        )
    }

    @discardableResult
    private func newTab(
        in targetController: BonsplitController,
        inPane paneId: PaneID? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        focusAfterCreate: Bool = true
    ) -> TabID? {
        guard let created = createSurfaceTab(
            in: targetController,
            paneId: paneId,
            source: .create(config: baseConfig)
        ) else { return nil }

        if focusAfterCreate {
            focusSurface(for: created.tabId, reason: .tabCreated)
        }
        return created.tabId
    }

    /// Adopt an existing surface into a new tab (e.g., from drag-out).
    /// Returns the tab ID if successful.
    @discardableResult
    func adoptSurface(
        _ surface: Ghostty.SurfaceView,
        inPane paneId: PaneID? = nil,
        focusAfterCreate: Bool = true
    ) -> TabID? {
        adoptSurface(
            surface,
            in: controller,
            inPane: paneId,
            focusAfterCreate: focusAfterCreate
        )
    }

    @discardableResult
    private func adoptSurface(
        _ surface: Ghostty.SurfaceView,
        in targetController: BonsplitController,
        inPane paneId: PaneID? = nil,
        focusAfterCreate: Bool = true
    ) -> TabID? {
        guard let created = createSurfaceTab(
            in: targetController,
            paneId: paneId,
            source: .adopt(surface)
        ) else { return nil }

        if focusAfterCreate {
            focusSurface(for: created.tabId, reason: .tabCreated)
        }
        return created.tabId
    }

    private func createSurfaceTab(
        in targetController: BonsplitController,
        paneId: PaneID? = nil,
        source: SurfaceSource
    ) -> CreatedSurfaceTab? {
        let surface: Ghostty.SurfaceView
        switch source {
        case .create(let config):
            guard let app = ghostty.app else { return nil }
            surface = Ghostty.SurfaceView(app, baseConfig: config)
        case .adopt(let existingSurface):
            surface = existingSurface
        }

        tabCounter += 1

        isCreatingBooManagedTab = true
        let tabId = targetController.createTab(
            title: source.initialTitle,
            inPane: paneId
        )
        isCreatingBooManagedTab = false

        guard let tabId else { return nil }

        registerSurface(surface, forTab: tabId)
        updateWindowChromeTabId()
        return CreatedSurfaceTab(
            tabId: tabId,
            surface: surface,
            controller: targetController
        )
    }

    private func registerSurface(_ surface: Ghostty.SurfaceView, forTab tabId: TabID) {
        surfaces[tabId] = surface
        observeSurface(surface, forTab: tabId)
    }

    /// Mirror ghostty's live surface title into Bonsplit's tab title, and
    /// title+pwd into the window chrome while this tab is focused.
    ///
    /// `Ghostty.SurfaceView.title` is `@Published` and starts as an empty
    /// string, then gets populated once the shell emits an OSC 2 /
    /// `$PROMPT_COMMAND` / `set_title` action. We ignore empty strings so
    /// the tab doesn't briefly show a blank label during startup; the
    /// initial "Terminal" placeholder stays until the shell reports its
    /// first real title.
    ///
    /// `SurfaceView.pwd` is updated from ghostty's `set_pwd` action (OSC 7
    /// / shell integration). When set on the focused tab, we feed it into
    /// `window.representedURL` so macOS draws the native proxy icon with
    /// drag + ⌘-click breadcrumb support. This is the same approach
    /// `BaseTerminalController.pwdDidChange` uses upstream.
    private func observeSurface(_ surface: Ghostty.SurfaceView, forTab tabId: TabID) {
        var subs: Set<AnyCancellable> = []

        surface.$title
            .removeDuplicates()
            .sink { [weak self] newTitle in
                guard let self else { return }
                if !newTitle.isEmpty {
                    self.controllerContaining(tabId: tabId)?.updateTab(tabId, title: newTitle)
                    self.objectWillChange.send()
                }
                if self.windowChromeTabId == tabId {
                    self.applyWindowChrome(title: newTitle, pwd: surface.pwd)
                }
            }
            .store(in: &subs)

        surface.$pwd
            .removeDuplicates()
            .sink { [weak self] newPwd in
                guard let self, self.windowChromeTabId == tabId else { return }
                self.applyWindowChrome(title: surface.title, pwd: newPwd)
            }
            .store(in: &subs)

        surfaceSubscriptions[tabId] = subs
    }

    // MARK: - Window chrome

    /// Recompute which tab's title/pwd the window should mirror, based on
    /// Bonsplit's focused pane + selected tab. Call after any focus or
    /// selection change.
    private func updateWindowChromeTabId() {
        let newId: TabID?
        if let paneId = controller.focusedPaneId,
           let tab = controller.selectedTab(inPane: paneId) {
            newId = tab.id
        } else {
            newId = nil
        }

        windowChromeTabId = newId

        if let newId, let surface = surfaces[newId] {
            applyWindowChrome(title: surface.title, pwd: surface.pwd)
        } else {
            applyWindowChrome(title: nil, pwd: nil)
        }
    }

    /// Push the computed title/pwd onto the hosting `NSWindow`. Setting
    /// `representedURL` alongside a non-empty title is what makes macOS
    /// draw the proxy icon; clearing both hides it.
    private func applyWindowChrome(title: String?, pwd: String?) {
        guard let window else { return }

        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayTitle = trimmed.isEmpty ? "Boo" : trimmed
        window.title = displayTitle
        windowChromeTitle = displayTitle

        if let pwd, !pwd.isEmpty {
            let url = URL(fileURLWithPath: pwd)
            window.representedURL = url
            windowChromeURL = url
        } else {
            window.representedURL = nil
            windowChromeURL = nil
        }
    }

    // MARK: - Split ops

    /// Split the pane containing `sourceSurface` in the given ghostty
    /// direction, spawning a fresh surface in the new pane. The source
    /// pane keeps its existing surface(s).
    private func splitPane(
        from sourceSurface: Ghostty.SurfaceView,
        direction: ghostty_action_split_direction_e,
        baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) {
        // Ghostty's 4 directions collapse to Bonsplit's 2 orientations
        // — we lose "which side", which is fine for MVP. Users mostly
        // split right/down anyway.
        let orientation: SplitOrientation
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT, GHOSTTY_SPLIT_DIRECTION_LEFT:
            orientation = .horizontal
        case GHOSTTY_SPLIT_DIRECTION_DOWN, GHOSTTY_SPLIT_DIRECTION_UP:
            orientation = .vertical
        default:
            return
        }

        guard let tabId = tabId(for: sourceSurface),
              let targetController = controllerContaining(tabId: tabId),
              let workspace = workspace(containing: targetController) else { return }

        activateWorkspace(.init(id: workspace.id, reason: .surfaceAction))

        // Stash the source and config for didSplitPane to pick up when
        // it spawns the new surface.
        pendingSplitSource = sourceSurface
        pendingSplitConfig = baseConfig
        _ = targetController.splitPane(orientation: orientation)
    }

    /// Temporary holder for the ghostty surface config to apply to the
    /// next surface created in response to a splitPane.
    private var pendingSplitConfig: Ghostty.SurfaceConfiguration?

    /// Temporary holder for the surface that requested the split. Used
    /// as the `from:` argument to `Ghostty.moveFocus` so AppKit's
    /// implicit `resignFirstResponder` isn't relied on for switching the
    /// cursor's focused-vs-unfocused style. Without this, the source
    /// pane visually keeps its focused (full-block) cursor even though
    /// typing goes to the new pane.
    private var pendingSplitSource: Ghostty.SurfaceView?

    /// Tab id for a given surface, if we own it.
    private func tabId(for surface: Ghostty.SurfaceView) -> TabID? {
        surfaces.first(where: { $0.value === surface })?.key
    }

    private func workspace(containing controller: BonsplitController) -> BooWorkspace? {
        workspaces.first { $0.controller === controller }
    }

    private func controllerContaining(tabId: TabID) -> BonsplitController? {
        workspaces.first { workspace in
            workspace.controller.allPaneIds.contains { paneId in
                workspace.controller.tabs(inPane: paneId).contains { $0.id == tabId }
            }
        }?.controller
    }

    private func controllerContaining(surface: Ghostty.SurfaceView) -> BonsplitController? {
        guard let tabId = tabId(for: surface) else { return nil }
        return controllerContaining(tabId: tabId)
    }

    // MARK: - Ghostty notification wiring

    private func subscribeToGhosttyNotifications() {
        let nc = NotificationCenter.default

        // Pass `object: nil` because we want to receive notifications from
        // any surface; we filter inside the handler by checking ownership.
        nc.addObserver(
            self,
            selector: #selector(onGhosttyNewTab(_:)),
            name: Ghostty.Notification.ghosttyNewTab,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onGhosttyNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onGhosttyCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onGhosttyFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onGhosttyGotoTab(_:)),
            name: Ghostty.Notification.ghosttyGotoTab,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onGhosttySurfaceFocusDidChange(_:)),
            name: .ghosttySurfaceFocusDidChange,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onGhosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )
    }

    @objc private func onGhosttyConfigDidChange(_ note: Notification) {
        // Update background color from new config
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.terminalBackgroundColor = self.ghostty.config.backgroundColor
        }
    }

    @objc private func onGhosttyNewTab(_ note: Notification) {
        // Two cases:
        //   * object is a SurfaceView we own          → create tab in this window
        //   * object is nil (app-level target)        → only the key Boo window handles it
        // If another window owns the originating surface, ignore.
        let targetController: BonsplitController
        if let surface = note.object as? Ghostty.SurfaceView {
            guard let sourceController = controllerContaining(surface: surface),
                  let workspace = workspace(containing: sourceController) else { return }
            activateWorkspace(.init(id: workspace.id, reason: .surfaceAction))
            targetController = sourceController
        } else {
            guard window?.isKeyWindow == true else { return }
            targetController = controller
        }

        let cfg = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            as? Ghostty.SurfaceConfiguration
        newTab(in: targetController, baseConfig: cfg)
    }

    @objc private func onGhosttyNewSplit(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              surfaces.values.contains(where: { $0 === surface }),
              let direction = note.userInfo?["direction"]
                as? ghostty_action_split_direction_e else { return }

        let cfg = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            as? Ghostty.SurfaceConfiguration
        splitPane(from: surface, direction: direction, baseConfig: cfg)
    }

    @objc private func onGhosttyCloseSurface(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tabId = tabId(for: surface),
              let sourceController = controllerContaining(tabId: tabId) else { return }
        // Route through `closeTab` so our `shouldCloseTab` gate handles
        // confirmation uniformly. The `process_alive` hint in the userInfo is
        // equivalent to the surface's `needsConfirmQuit`, which is what the
        // gate already checks.
        _ = sourceController.closeTab(tabId)
    }

    /// Handle ⌘⌥arrow (and ⌘[ / ⌘] for previous/next) by asking Bonsplit
    /// to move focus between panes spatially. Ghostty emits this from its
    /// core `goto_split` action; our job is to translate the direction into
    /// Bonsplit's own navigation API and then push AppKit focus into the
    /// newly-focused pane's surface.
    @objc private func onGhosttyFocusSplit(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tabId = tabId(for: surface),
              let sourceController = controllerContaining(tabId: tabId),
              let sourceWorkspace = workspace(containing: sourceController),
              let direction = note.userInfo?[Ghostty.Notification.SplitDirectionKey]
                as? Ghostty.SplitFocusDirection,
              let navDirection = Self.navigationDirection(for: direction),
              let sourcePaneId = paneContaining(tabId: tabId, in: sourceController) else { return }

        activateWorkspace(.init(id: sourceWorkspace.id, reason: .surfaceAction))

        // Sync Bonsplit's focused-pane state with the actual source pane
        // before navigating. `navigateFocus` uses `focusedPaneId` as its
        // starting point; if the user has been navigating via keybinds
        // without clicking, Bonsplit's state should already match, but
        // re-focusing is cheap and avoids drifting.
        sourceController.focusPane(sourcePaneId)
        sourceController.navigateFocus(direction: navDirection)

        // Bonsplit updates `focusedPaneId`, but first-responder still lives
        // on the previous surface. Push AppKit focus into the new pane's
        // selected-tab surface so typing lands in the right terminal.
        focusCurrentTabSurface(reason: .paneFocused)
    }

    /// Handle ⌘1–9 / ⌘⇧[ / ⌘⇧] (and config-remapped equivalents) by
    /// navigating tabs *within the focused Bonsplit pane*. Unlike ghostty's
    /// native tabs (one per NSWindow in an AppKit tab group), Bonsplit's
    /// tabs are per-pane, so `goto_tab` targets the pane that owns the
    /// source surface.
    @objc private func onGhosttyGotoTab(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tabId = tabId(for: surface),
              let sourceController = controllerContaining(tabId: tabId),
              let sourceWorkspace = workspace(containing: sourceController),
              let tabEnum = note.userInfo?[Ghostty.Notification.GotoTabKey]
                as? ghostty_action_goto_tab_e,
              let paneId = paneContaining(tabId: tabId, in: sourceController) else { return }

        activateWorkspace(.init(id: sourceWorkspace.id, reason: .surfaceAction))

        let tabs = sourceController.tabs(inPane: paneId)
        guard tabs.count > 1 else { return }

        // ghostty's goto_tab enum uses:
        //   - `rawValue >= 1` for 1-indexed absolute navigation (clamp to last)
        //   - negative sentinels for PREVIOUS / NEXT / LAST (with wrap-around
        //     for prev/next to match macOS Terminal behaviour)
        let rawValue = tabEnum.rawValue
        let currentIndex = tabs.firstIndex(where: { $0.id == tabId }) ?? 0
        let finalIndex: Int

        if rawValue >= 1 {
            finalIndex = min(Int(rawValue) - 1, tabs.count - 1)
        } else if rawValue == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
            finalIndex = currentIndex == 0 ? tabs.count - 1 : currentIndex - 1
        } else if rawValue == GHOSTTY_GOTO_TAB_NEXT.rawValue {
            finalIndex = currentIndex == tabs.count - 1 ? 0 : currentIndex + 1
        } else if rawValue == GHOSTTY_GOTO_TAB_LAST.rawValue {
            finalIndex = tabs.count - 1
        } else {
            return
        }

        guard finalIndex != currentIndex else { return }
        sourceController.selectTab(tabs[finalIndex].id)
    }

    /// Sync Bonsplit pane focus from the actual AppKit surface that became
    /// first responder. This is more reliable than SwiftUI wrapper gestures:
    /// if a click focuses pane 1's terminal, we want Bonsplit to follow the
    /// surface that *actually* gained focus, not whichever SwiftUI wrapper
    /// happened to receive a gesture in an overlapping/unstable hit-test pass.
    @objc private func onGhosttySurfaceFocusDidChange(_ note: Notification) {
        // Skip if we're already in the middle of changing focus to avoid loops.
        guard !isChangingFocus else { return }

        guard let surface = note.object as? Ghostty.SurfaceView,
              surfaces.values.contains(where: { $0 === surface }),
              let focused = note.userInfo?["focused"] as? Bool,
              focused,
              let tabId = tabId(for: surface),
              let sourceController = controllerContaining(tabId: tabId),
              let sourceWorkspace = workspace(containing: sourceController),
              let paneId = paneContaining(tabId: tabId, in: sourceController) else { return }

        activateWorkspace(.init(id: sourceWorkspace.id, reason: .surfaceAction))

        focusedOwnedSurface = surface

        let current = sourceController.focusedPaneId
        if current != paneId {
            // Set the guard before calling focusPane to prevent didFocusPane
            // from triggering another focus change.
            isChangingFocus = true
            sourceController.focusPane(paneId)
            isChangingFocus = false
        }
    }

    /// Bonsplit's 4-way spatial navigation doesn't have a tree-order
    /// previous/next concept, so we approximate: `.previous` → `.left`,
    /// `.next` → `.right`. Users remapping those to vertical directions
    /// will need to update their keybinds.
    private static func navigationDirection(
        for d: Ghostty.SplitFocusDirection
    ) -> NavigationDirection? {
        switch d {
        case .left, .previous: return .left
        case .right, .next:    return .right
        case .up:              return .up
        case .down:            return .down
        }
    }

    private func selectedTabId(in workspace: BooWorkspace) -> TabID? {
        if let focusedPaneId = workspace.controller.focusedPaneId,
           let tab = workspace.controller.selectedTab(inPane: focusedPaneId) {
            return tab.id
        }

        for paneId in workspace.controller.allPaneIds {
            if let tab = workspace.controller.selectedTab(inPane: paneId) {
                return tab.id
            }
        }

        return nil
    }

    /// Look up which Bonsplit pane currently hosts the given tab.
    private func paneContaining(
        tabId: TabID,
        in targetController: BonsplitController? = nil
    ) -> PaneID? {
        let targetController = targetController ?? controllerContaining(tabId: tabId) ?? controller
        return targetController.allPaneIds.first { paneId in
            targetController.tabs(inPane: paneId).contains { $0.id == tabId }
        }
    }
}

// MARK: - BonsplitDelegate

@MainActor
extension BooState: BonsplitDelegate {
    /// Gate tab close on a confirmation alert when the surface still has a
    /// running child process. Returning `false` vetoes the close; on OK we
    /// reinvoke `closeTab` with the id pre-authorized.
    func splitTabBar(
        _ controller: BonsplitController,
        shouldCloseTab tab: Tab,
        inPane pane: PaneID
    ) -> Bool {
        // Second pass after the user confirmed - let it through.
        if confirmedCloseTabIds.remove(tab.id) != nil {
            return true
        }

        // If the tab's surface doesn't need confirmation, close immediately.
        guard let surface = surfaces[tab.id], surface.needsConfirmQuit else {
            return true
        }

        // Show confirmation; on OK, pre-authorize and retry the close.
        presentCloseConfirmation(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            guard let self else { return }
            self.confirmedCloseTabIds.insert(tab.id)
            _ = controller.closeTab(tab.id, inPane: pane)
        }
        return false
    }

    /// Gate pane close on a confirmation alert if any tab in the pane has a
    /// running process. Mirrors `shouldCloseTab` but aggregates across every
    /// surface in the pane.
    func splitTabBar(
        _ controller: BonsplitController,
        shouldClosePane pane: PaneID
    ) -> Bool {
        if confirmedClosePaneIds.remove(pane) != nil {
            return true
        }

        let paneSurfaces = controller.tabs(inPane: pane).compactMap { surfaces[$0.id] }
        guard paneSurfaces.contains(where: { $0.needsConfirmQuit }) else {
            return true
        }

        presentCloseConfirmation(
            messageText: "Close Split?",
            informativeText: "A terminal in this split still has a running process. If you close the split the process will be killed."
        ) { [weak self] in
            guard let self else { return }
            self.confirmedClosePaneIds.insert(pane)
            _ = controller.closePane(pane)
        }
        return false
    }

    /// Show the close-confirmation alert as a sheet on our window.
    /// No-ops when another confirmation is already on screen so a burst of
    /// close requests doesn't stack alerts.
    func presentCloseConfirmation(
        messageText: String,
        informativeText: String,
        onConfirm: @escaping () -> Void
    ) {
        guard !isShowingCloseConfirmation else { return }
        guard let window else {
            // No window to attach to - just proceed.
            onConfirm()
            return
        }

        isShowingCloseConfirmation = true
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            // Order the alert window out first to avoid focus-loss glitches
            // under Stage Manager (same workaround as ghostty's upstream).
            alert.window.orderOut(nil)
            self?.isShowingCloseConfirmation = false
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }

    /// Free the surface when its tab is closed. Without this the surface
    /// (and its child process) would leak for the lifetime of the window.
    ///
    /// Also closes the enclosing window when the last surface goes away,
    /// which is what users expect when they `exit` the shell in the only
    /// tab of the only pane.
    func splitTabBar(
        _ controller: BonsplitController,
        didCloseTab tabId: TabID,
        fromPane pane: PaneID
    ) {
        let closingSurface = surfaces[tabId]
        let closingSurfaceWasFocused = closingSurface.map {
            focusedOwnedSurface === $0 || window?.firstResponder === $0
        } ?? false

        // Break retain cycle between SurfaceView and SurfaceScrollView
        if let closingSurface {
            closingSurface.cachedScrollView = nil
            if closingSurfaceWasFocused {
                closingSurface.focusDidChange(false)
                focusedOwnedSurface = nil
            }
        }
        surfaces.removeValue(forKey: tabId)
        surfaceSubscriptions.removeValue(forKey: tabId)
        updateWindowChromeTabId()

        if surfaces.isEmpty {
            // Hide immediately to avoid visible empty window, but defer
            // the actual close so Bonsplit finishes its bookkeeping
            // (important for drag-to-split where new panes are being created).
            window?.orderOut(nil)
            DispatchQueue.main.async { [weak self] in
                self?.window?.performClose(nil)
            }
        } else if controller.allPaneIds.isEmpty {
            removeWorkspace(for: controller)
        } else if !isDraggingTabOut && (closingSurfaceWasFocused || controller.focusedPaneId == pane) {
            // Focus the replacement surface from the closing surface when
            // possible. This keeps AppKit's first responder from lingering on
            // the just-removed tab during rapid shell exits (e.g. holding
            // Ctrl-D), while preserving drag-out's no-refocus source-window
            // behavior.
            if controller.allPaneIds.contains(pane) {
                focusCurrentTabSurface(
                    inPane: pane,
                    from: closingSurface,
                    reason: .tabClosed,
                    immediately: true
                )
            } else {
                focusCurrentTabSurface(
                    from: closingSurface,
                    reason: .tabClosed,
                    immediately: true
                )
            }
        }
        // Note: structural recovery (epoch bump, focus) is handled by
        // didClosePane below. A plain tab close that leaves the pane
        // intact doesn't need any remount — the surface NSViews stay
        // correctly parented.
    }

    /// Called when Bonsplit actually destroys a pane (last tab in the
    /// pane closed and other panes exist, so the split tree collapses).
    /// After the collapse, SwiftUI reparents the surviving surface; we just
    /// need to push AppKit focus into the newly-active pane's surface since
    /// Bonsplit only flips its own focused-pane state.
    func splitTabBar(
        _ controller: BonsplitController,
        didClosePane paneId: PaneID
    ) {
        // Capture flags now - they may change by the time async runs.
        let shouldRefocus = !isChangingFocus && !isDraggingTabOut

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if shouldRefocus {
                self.focusCurrentTabSurface(reason: .paneClosed)
            }
            self.updateWindowChromeTabId()
        }
    }

    /// After Bonsplit creates the new pane from a split, populate it with
    /// a fresh ghostty surface — unless the pane already has a tab with a
    /// surface (drag-drop moved an existing tab into the new pane).
    func splitTabBar(
        _ controller: BonsplitController,
        didSplitPane originalPane: PaneID,
        newPane: PaneID,
        orientation: SplitOrientation
    ) {
        let cfg = pendingSplitConfig
        let source = pendingSplitSource ?? focusedOwnedSurface
        pendingSplitConfig = nil
        pendingSplitSource = nil

        // Check if the new pane already has a tab with a surface (drag-drop
        // moved an existing tab). If so, just focus it instead of creating
        // a new surface.
        let existingTabs = controller.tabs(inPane: newPane)
        if let existingTab = existingTabs.first,
           surfaces[existingTab.id] != nil {
            focusSurface(for: existingTab.id, from: source, reason: .splitCreated)
            return
        }

        // Create a fresh surface in the new pane.
        // If the focused pane is different from newPane, this is the
        // drag-to-split-within-same-pane async replacement for the
        // emptied source pane — don't steal focus from the dragged tab.
        let shouldFocus = (controller.focusedPaneId == newPane)

        guard let tabId = newTab(in: controller, inPane: newPane, baseConfig: cfg, focusAfterCreate: false) else {
            return
        }

        // Move AppKit first responder to the new surface only if it should focus.
        if shouldFocus {
            focusSurface(for: tabId, from: source, reason: .splitCreated)
        }
    }

    /// Create a surface for tabs created by Bonsplit (e.g. + button in tab bar).
    /// Tabs created via `newTab()` already have surfaces attached.
    func splitTabBar(
        _ controller: BonsplitController,
        didCreateTab tab: Tab,
        inPane pane: PaneID
    ) {
        // Skip tabs created by Boo's own `newTab`/`adoptSurface` paths.
        // `createTab` invokes this delegate synchronously before those paths
        // can store their SurfaceView in `surfaces`.
        guard !isCreatingBooManagedTab else { return }

        // Skip if this tab already has a surface.
        guard surfaces[tab.id] == nil else { return }
        guard let app = ghostty.app else { return }

        // Create a new surface for this tab
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, uuid: tab.id.id)
        registerSurface(surface, forTab: tab.id)
        focusSurface(for: tab.id, reason: .tabCreated)
        updateWindowChromeTabId()
    }

    /// Focus the surface when the user switches tabs.
    func splitTabBar(
        _ controller: BonsplitController,
        didSelectTab tab: Tab,
        inPane pane: PaneID
    ) {
        // Capture flag now - it may change by the time async runs.
        let wasDraggingOut = isDraggingTabOut

        // Defer one runloop tick so SwiftUI/AppKit finish any tab reparenting
        // first (notably drag-dropping a tab onto another pane's tab bar).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Skip focus if this was triggered by drag-out (focus goes to new window).
            if !wasDraggingOut {
                self.focusSurface(for: tab.id, reason: .tabSelected)
            }
            self.updateWindowChromeTabId()
        }
    }

    /// Track pane focus changes (e.g., user clicks into a different pane)
    /// so the window title/proxy icon switch to reflect the newly active
    /// pane's selected tab.
    func splitTabBar(
        _ controller: BonsplitController,
        didFocusPane pane: PaneID
    ) {
        updateWindowChromeTabId()
        // Skip if we're in the middle of a focus change to avoid loops.
        guard !isChangingFocus else { return }
        // Also push AppKit focus into the pane's selected surface.
        // This handles the case where the user clicks an already-selected
        // tab in another pane: didSelectTab doesn't fire (tab was already
        // selected), but we still need to move first-responder.
        focusCurrentTabSurface(reason: .paneFocused)
    }

    // MARK: - Focus coordination

    enum TerminalFocusReason {
        case workspaceActivated
        case tabCreated
        case tabSelected
        case tabClosed
        case paneClosed
        case paneFocused
        case splitCreated
        case windowActivated
        case explicit
    }

    /// Move AppKit first-responder focus to this tab's surface.
    private func focusSurface(
        for tabId: TabID,
        from source: Ghostty.SurfaceView? = nil,
        reason: TerminalFocusReason = .explicit,
        immediately: Bool = false
    ) {
        guard let surface = surfaces[tabId] else { return }

        if let targetController = controllerContaining(tabId: tabId),
           let workspace = workspace(containing: targetController),
           activeWorkspaceId != workspace.id {
            activateWorkspace(.init(id: workspace.id, reason: .userSwitch))
            DispatchQueue.main.async { [weak self, source] in
                self?.focusSurface(
                    for: tabId,
                    from: source,
                    reason: reason,
                    immediately: immediately
                )
            }
            return
        }

        // Skip if this surface is already the actual first responder.
        // We check both our tracking variable AND the actual AppKit state
        // because drag operations can steal first-responder without updating
        // our tracking.
        let isActualFirstResponder = surface.window?.firstResponder === surface
        if focusedOwnedSurface === surface && isActualFirstResponder {
            // The AppKit first responder can survive a window/app deactivate
            // while Boo has marked the surface unfocused for cursor visuals.
            // Restore the surface focus state when no responder handoff is
            // needed so the cursor becomes filled again.
            if surface.window?.isKeyWindow == true {
                surface.focusDidChange(true)
            }
            return
        }

        // Prevent re-entrant focus changes that could cause oscillation.
        guard !isChangingFocus else { return }
        isChangingFocus = true
        defer { isChangingFocus = false }

        let previous = source ?? focusedOwnedSurface
        if immediately, let window = surface.window {
            if let previous, previous !== surface {
                _ = previous.resignFirstResponder()
                previous.focusDidChange(false)
            }
            window.makeFirstResponder(surface)
            if window.isKeyWindow {
                surface.focusDidChange(true)
            }
        } else if let previous, previous !== surface {
            Ghostty.moveFocus(to: surface, from: previous)
        } else {
            Ghostty.moveFocus(to: surface)
        }

        focusedOwnedSurface = surface
    }

    /// Focus the currently selected tab's surface. Called from
    /// `BooController.windowDidBecomeKey` so reactivating the window also
    /// restores terminal focus without requiring a click.
    func focusCurrentTabSurface(
        from source: Ghostty.SurfaceView? = nil,
        reason: TerminalFocusReason = .explicit,
        immediately: Bool = false
    ) {
        guard let paneId = controller.focusedPaneId else { return }
        focusCurrentTabSurface(
            inPane: paneId,
            from: source,
            reason: reason,
            immediately: immediately
        )
    }

    func focusCurrentTabSurface(
        inPane paneId: PaneID,
        from source: Ghostty.SurfaceView? = nil,
        reason: TerminalFocusReason = .explicit,
        immediately: Bool = false
    ) {
        guard let tab = controller.selectedTab(inPane: paneId) else { return }
        focusSurface(
            for: tab.id,
            from: source,
            reason: reason,
            immediately: immediately
        )
    }

    /// Unfocus all surfaces when the window loses key status.
    /// This makes cursors hollow to indicate the window is inactive.
    /// Note: we don't clear focusedOwnedSurface so we can refocus it
    /// when the window becomes key again.
    func unfocusAllSurfaces() {
        for surface in surfaces.values {
            surface.focusDidChange(false)
        }
    }

    /// Update window key state.
    func setWindowKey(_ isKey: Bool) {
        isWindowKey = isKey
    }

    /// Refocus the current surface when the window becomes key.
    func refocusCurrentSurface() {
        if let surface = focusedOwnedSurface,
           surfaces.values.contains(where: { $0 === surface }) {
            if surface.window?.isKeyWindow == true,
               surface.window?.firstResponder === surface {
                surface.focusDidChange(true)
            } else if let tabId = tabId(for: surface) {
                focusSurface(for: tabId, reason: .windowActivated)
            }
        } else {
            focusedOwnedSurface = nil
            focusCurrentTabSurface(reason: .windowActivated)
        }
    }

    // MARK: - Menu Action Helpers

    /// Close the current tab in the focused pane.
    func closeCurrentTab() {
        guard let paneId = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: paneId) else { return }
        _ = controller.closeTab(tab.id)
    }

    /// Close the current pane. If only one pane exists, closes the current tab.
    func closeCurrentPane() {
        // If there's only one pane, close the current tab instead
        if controller.allPaneIds.count <= 1 {
            closeCurrentTab()
        } else {
            // Close the focused pane
            guard let paneId = controller.focusedPaneId else { return }
            _ = controller.closePane(paneId)
        }
    }

    /// Inherited surface config from the currently focused surface for a
    /// given creation context (window/tab/split). Returns nil when no owned
    /// surface is focused, in which case ghostty falls back to normal defaults.
    func inheritedConfigForFocusedSurface(
        context: ghostty_surface_context_e
    ) -> Ghostty.SurfaceConfiguration? {
        guard let cSurface = focusedOwnedSurface?.surface else { return nil }
        return Ghostty.SurfaceConfiguration(
            from: ghostty_surface_inherited_config(cSurface, context)
        )
    }

    /// Split the current pane in the given direction.
    func splitCurrentPane(direction: SplitDirection) {
        guard let paneId = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: paneId),
              let surface = surfaces[tab.id] else { return }
        splitPane(
            from: surface,
            direction: ghosttyDirection(for: direction),
            baseConfig: inheritedConfigForFocusedSurface(
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT
            )
        )
    }

    /// Convert our SplitDirection to ghostty's split direction.
    private func ghosttyDirection(for direction: SplitDirection) -> ghostty_action_split_direction_e {
        switch direction {
        case .right: return GHOSTTY_SPLIT_DIRECTION_RIGHT
        case .left: return GHOSTTY_SPLIT_DIRECTION_LEFT
        case .down: return GHOSTTY_SPLIT_DIRECTION_DOWN
        case .up: return GHOSTTY_SPLIT_DIRECTION_UP
        }
    }

    /// Adjust font size for all surfaces.
    func adjustFontSize(delta: Int) {
        for surface in surfaces.values {
            if let s = surface.surface {
                let change: Ghostty.App.FontSizeModification = delta > 0
                    ? .increase(delta)
                    : .decrease(-delta)
                ghostty.changeFontSize(surface: s, change)
            }
        }
    }

    /// Reset font size for all surfaces.
    func resetFontSize() {
        for surface in surfaces.values {
            if let s = surface.surface {
                ghostty.changeFontSize(surface: s, .reset)
            }
        }
    }

    /// Navigate between Bonsplit panes.
    func navigatePanes(direction: PaneNavigationDirection) {
        switch direction {
        case .left:
            controller.navigateFocus(direction: .left)
        case .right:
            controller.navigateFocus(direction: .right)
        case .up:
            controller.navigateFocus(direction: .up)
        case .down:
            controller.navigateFocus(direction: .down)
        case .previous, .next:
            // For previous/next, cycle through panes in order
            let panes = controller.allPaneIds
            guard panes.count > 1,
                  let currentPane = controller.focusedPaneId,
                  let currentIndex = panes.firstIndex(of: currentPane) else { return }

            let nextIndex: Int
            if direction == .next {
                nextIndex = (currentIndex + 1) % panes.count
            } else {
                nextIndex = (currentIndex - 1 + panes.count) % panes.count
            }
            controller.focusPane(panes[nextIndex])
        }
        // Focus the surface in the newly focused pane
        focusCurrentTabSurface(reason: .paneFocused)
    }
}

/// Direction for splitting panes.
public enum SplitDirection {
    case right, left, down, up
}

/// Direction for pane navigation.
public enum PaneNavigationDirection {
    case left, right, up, down, previous, next
}
