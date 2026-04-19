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

    let controller: BonsplitController

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

    /// Flag to skip auto-focus during tab drag-out operations.
    private var isDraggingTabOut: Bool = false

    private var tabCounter = 0

    init(ghostty: Ghostty.App, baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        self.ghostty = ghostty
        self.terminalBackgroundColor = ghostty.config.backgroundColor

        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            contentViewLifecycle: .keepAllAlive
        )
        self.controller = BonsplitController(configuration: config)
        self.controller.delegate = self
        setupTabDragOutCallback()

        subscribeToGhosttyNotifications()

        // Seed one initial tab so the window isn't empty on open.
        // Bonsplit starts with no panes; the first createTab bootstraps the tree.
        newTab(baseConfig: baseConfig)
    }

    /// Init with an existing surface (for drag-out-to-new-window).
    init(ghostty: Ghostty.App, existingSurface: Ghostty.SurfaceView) {
        self.ghostty = ghostty
        self.terminalBackgroundColor = ghostty.config.backgroundColor

        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            contentViewLifecycle: .keepAllAlive
        )
        self.controller = BonsplitController(configuration: config)
        self.controller.delegate = self
        setupTabDragOutCallback()

        subscribeToGhosttyNotifications()

        // Adopt the existing surface instead of creating a new one.
        adoptSurface(existingSurface)
    }

    /// Set up callback for when a tab is dragged outside all windows.
    private func setupTabDragOutCallback() {
        controller.onTabDragEndedOutside = { [weak self] tab, sourcePaneId, screenPoint in
            self?.handleTabDraggedOutside(tab: tab, at: screenPoint)
        }
    }

    /// Handle a tab being dragged outside all windows - create a new window.
    private func handleTabDraggedOutside(tab: Tab, at screenPoint: NSPoint?) {
        // Get the surface for this tab
        guard let surface = surfaces[tab.id] else { return }

        // Only drag out if there's more than one tab/split total
        let totalTabs = controller.allPaneIds.reduce(0) { $0 + controller.tabs(inPane: $1).count }
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
        controller.closeTab(tab.id)

        // Unfocus all surfaces in this window
        unfocusAllSurfaces()

        // Create new window with the dragged surface
        _ = BooController.newWindow(ghostty, withSurface: surface, position: screenPoint)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Tab ops

    /// Create a new Bonsplit tab and spawn a fresh ghostty surface into it.
    /// If `paneId` is nil, the tab goes to Bonsplit's focused pane.
    /// If `focusAfterCreate` is false, focus is not moved to the new surface.
    @discardableResult
    func newTab(
        inPane paneId: PaneID? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil,
        focusAfterCreate: Bool = true
    ) -> TabID? {
        guard let app = ghostty.app else { return nil }

        tabCounter += 1
        let surface = Ghostty.SurfaceView(app, baseConfig: baseConfig)

        guard let tabId = controller.createTab(
            title: "👻",
            inPane: paneId
        ) else { return nil }

        // We store the surface AFTER createTab returns (since Bonsplit
        // gives us the tabId then) and manually focus, because Bonsplit's
        // didCreateTab/didSelectTab hooks fire synchronously inside
        // createTab — at which point our map is still empty.
        surfaces[tabId] = surface
        observeSurface(surface, forTab: tabId)
        if focusAfterCreate {
            focusSurface(for: tabId)
        }
        updateWindowChromeTabId()
        return tabId
    }

    /// Adopt an existing surface into a new tab (e.g., from drag-out).
    /// Returns the tab ID if successful.
    @discardableResult
    func adoptSurface(
        _ surface: Ghostty.SurfaceView,
        inPane paneId: PaneID? = nil,
        focusAfterCreate: Bool = true
    ) -> TabID? {
        tabCounter += 1

        guard let tabId = controller.createTab(
            title: surface.title.isEmpty ? "👻" : surface.title,
            inPane: paneId
        ) else { return nil }

        surfaces[tabId] = surface
        observeSurface(surface, forTab: tabId)
        if focusAfterCreate {
            focusSurface(for: tabId)
        }
        updateWindowChromeTabId()
        return tabId
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
                    self.controller.updateTab(tabId, title: newTitle)
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
        window.title = trimmed.isEmpty ? "Boo" : trimmed

        if let pwd, !pwd.isEmpty {
            window.representedURL = URL(fileURLWithPath: pwd)
        } else {
            window.representedURL = nil
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

        // Stash the source and config for didSplitPane to pick up when
        // it spawns the new surface.
        pendingSplitSource = sourceSurface
        pendingSplitConfig = baseConfig
        _ = controller.splitPane(orientation: orientation)
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
        nc.addObserver(
            self,
            selector: #selector(onGhosttySurfaceDragEndedNoTarget(_:)),
            name: .ghosttySurfaceDragEndedNoTarget,
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
        if let surface = note.object as? Ghostty.SurfaceView {
            guard surfaces.values.contains(where: { $0 === surface }) else { return }
        } else {
            guard window?.isKeyWindow == true else { return }
        }

        let cfg = note.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
            as? Ghostty.SurfaceConfiguration
        newTab(baseConfig: cfg)
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
              let tabId = tabId(for: surface) else { return }
        _ = controller.closeTab(tabId)
    }

    /// Handle ⌘⌥arrow (and ⌘[ / ⌘] for previous/next) by asking Bonsplit
    /// to move focus between panes spatially. Ghostty emits this from its
    /// core `goto_split` action; our job is to translate the direction into
    /// Bonsplit's own navigation API and then push AppKit focus into the
    /// newly-focused pane's surface.
    @objc private func onGhosttyFocusSplit(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tabId = tabId(for: surface),
              let direction = note.userInfo?[Ghostty.Notification.SplitDirectionKey]
                as? Ghostty.SplitFocusDirection,
              let navDirection = Self.navigationDirection(for: direction),
              let sourcePaneId = paneContaining(tabId: tabId) else { return }

        // Sync Bonsplit's focused-pane state with the actual source pane
        // before navigating. `navigateFocus` uses `focusedPaneId` as its
        // starting point; if the user has been navigating via keybinds
        // without clicking, Bonsplit's state should already match, but
        // re-focusing is cheap and avoids drifting.
        controller.focusPane(sourcePaneId)
        controller.navigateFocus(direction: navDirection)

        // Bonsplit updates `focusedPaneId`, but first-responder still lives
        // on the previous surface. Push AppKit focus into the new pane's
        // selected-tab surface so typing lands in the right terminal.
        focusCurrentTabSurface()
    }

    /// Handle ⌘1–9 / ⌘⇧[ / ⌘⇧] (and config-remapped equivalents) by
    /// navigating tabs *within the focused Bonsplit pane*. Unlike ghostty's
    /// native tabs (one per NSWindow in an AppKit tab group), Bonsplit's
    /// tabs are per-pane, so `goto_tab` targets the pane that owns the
    /// source surface.
    @objc private func onGhosttyGotoTab(_ note: Notification) {
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tabId = tabId(for: surface),
              let tabEnum = note.userInfo?[Ghostty.Notification.GotoTabKey]
                as? ghostty_action_goto_tab_e,
              let paneId = paneContaining(tabId: tabId) else { return }

        let tabs = controller.tabs(inPane: paneId)
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
        controller.selectTab(tabs[finalIndex].id)
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
              let paneId = paneContaining(tabId: tabId) else { return }

        focusedOwnedSurface = surface

        let current = controller.focusedPaneId
        if current != paneId {
            // Set the guard before calling focusPane to prevent didFocusPane
            // from triggering another focus change.
            isChangingFocus = true
            controller.focusPane(paneId)
            isChangingFocus = false
        }
    }

    @objc private func onGhosttySurfaceDragEndedNoTarget(_ note: Notification) {
        // Surface was dragged outside any valid drop target - create new window.
        guard let surface = note.object as? Ghostty.SurfaceView,
              let tabId = tabId(for: surface),
              let app = ghostty.app else { return }

        // Only handle if we have more than one tab/split, otherwise it's a no-op
        // (dragging the only surface out of its window makes no sense).
        let totalTabs = controller.allPaneIds.reduce(0) { $0 + controller.tabs(inPane: $1).count }
        guard totalTabs > 1 else { return }

        // Remove from our tracking
        surfaces.removeValue(forKey: tabId)
        surfaceSubscriptions.removeValue(forKey: tabId)
        controller.closeTab(tabId)

        // Create new window with the dragged surface
        let position = note.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint
        _ = BooController.newWindow(ghostty, withSurface: surface, position: position)
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

    /// Look up which Bonsplit pane currently hosts the given tab.
    private func paneContaining(tabId: TabID) -> PaneID? {
        controller.allPaneIds.first { paneId in
            controller.tabs(inPane: paneId).contains { $0.id == tabId }
        }
    }
}

// MARK: - BonsplitDelegate

@MainActor
extension BooState: BonsplitDelegate {
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
        // Break retain cycle between SurfaceView and SurfaceScrollView
        if let surface = surfaces[tabId] {
            surface.cachedScrollView = nil
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
        } else if controller.focusedPaneId == pane && !isDraggingTabOut {
            // Focus the newly selected tab in this pane (if any).
            // This handles the case where the closed tab was focused.
            // Skip this during drag-out since focus will move to new window.
            focusCurrentTabSurface(inPane: pane)
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
                self.focusCurrentTabSurface()
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
        if let existingTab = existingTabs.first, let existingSurface = surfaces[existingTab.id] {
            if let source, source !== existingSurface {
                Ghostty.moveFocus(to: existingSurface, from: source)
            } else {
                Ghostty.moveFocus(to: existingSurface)
            }
            focusedOwnedSurface = existingSurface
            return
        }

        // Create a fresh surface in the new pane.
        // If the focused pane is different from newPane, this is the
        // drag-to-split-within-same-pane async replacement for the
        // emptied source pane — don't steal focus from the dragged tab.
        let shouldFocus = (controller.focusedPaneId == newPane)
        
        guard let tabId = newTab(inPane: newPane, baseConfig: cfg, focusAfterCreate: shouldFocus),
              let newSurface = surfaces[tabId] else {
            return
        }

        // Move AppKit first responder to the new surface only if it should focus.
        if shouldFocus, let source, source !== newSurface {
            Ghostty.moveFocus(to: newSurface, from: source)
            focusedOwnedSurface = newSurface
        }
    }

    /// Create a surface for tabs created by Bonsplit (e.g. + button in tab bar).
    /// Tabs created via `newTab()` already have surfaces attached.
    func splitTabBar(
        _ controller: BonsplitController,
        didCreateTab tab: Tab,
        inPane pane: PaneID
    ) {
        // Skip if this tab already has a surface (created via newTab)
        guard surfaces[tab.id] == nil else { return }
        guard let app = ghostty.app else { return }
        
        // Create a new surface for this tab
        let surface = Ghostty.SurfaceView(app, baseConfig: nil, uuid: tab.id.id)
        surfaces[tab.id] = surface
        observeSurface(surface, forTab: tab.id)
        focusSurface(for: tab.id)
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
                self.focusSurface(for: tab.id)
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
        focusCurrentTabSurface()
    }

    /// Move AppKit first-responder focus to this tab's surface.
    private func focusSurface(for tabId: TabID) {
        guard let surface = surfaces[tabId] else { return }
        
        // Skip if this surface is already the actual first responder.
        // We check both our tracking variable AND the actual AppKit state
        // because drag operations can steal first-responder without updating
        // our tracking.
        let isActualFirstResponder = surface.window?.firstResponder === surface
        if focusedOwnedSurface === surface && isActualFirstResponder {
            return
        }
        
        // Prevent re-entrant focus changes that could cause oscillation.
        guard !isChangingFocus else { return }
        isChangingFocus = true
        defer { isChangingFocus = false }

        if let previous = focusedOwnedSurface, previous !== surface {
            Ghostty.moveFocus(to: surface, from: previous)
        } else {
            Ghostty.moveFocus(to: surface)
        }

        focusedOwnedSurface = surface
    }

    /// Focus the currently selected tab's surface. Called from
    /// `BooController.windowDidBecomeKey` so reactivating the window also
    /// restores terminal focus without requiring a click.
    func focusCurrentTabSurface() {
        guard let paneId = controller.focusedPaneId else { return }
        focusCurrentTabSurface(inPane: paneId)
    }
    
    func focusCurrentTabSurface(inPane paneId: PaneID) {
        guard let tab = controller.selectedTab(inPane: paneId) else { return }
        focusSurface(for: tab.id)
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
        if let surface = focusedOwnedSurface {
            surface.focusDidChange(true)
        } else {
            focusCurrentTabSurface()
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
    
    /// Split the current pane in the given direction.
    func splitCurrentPane(direction: SplitDirection) {
        guard let paneId = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: paneId),
              let surface = surfaces[tab.id] else { return }
        splitPane(from: surface, direction: ghosttyDirection(for: direction), baseConfig: nil)
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
        focusCurrentTabSurface()
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
