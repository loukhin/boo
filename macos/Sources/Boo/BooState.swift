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

    private var tabCounter = 0

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty

        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            contentViewLifecycle: .keepAllAlive
        )
        self.controller = BonsplitController(configuration: config)
        self.controller.delegate = self

        subscribeToGhosttyNotifications()

        // Seed one initial tab so the window isn't empty on open.
        // Bonsplit starts with no panes; the first createTab bootstraps the tree.
        newTab()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Tab ops

    /// Create a new Bonsplit tab and spawn a fresh ghostty surface into it.
    /// If `paneId` is nil, the tab goes to Bonsplit's focused pane.
    @discardableResult
    func newTab(
        inPane paneId: PaneID? = nil,
        baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> TabID? {
        guard let app = ghostty.app else { return nil }

        tabCounter += 1
        let surface = Ghostty.SurfaceView(app, baseConfig: baseConfig)

        guard let tabId = controller.createTab(
            title: "Terminal",
            icon: nil,
            inPane: paneId
        ) else { return nil }

        // We store the surface AFTER createTab returns (since Bonsplit
        // gives us the tabId then) and manually focus, because Bonsplit's
        // didCreateTab/didSelectTab hooks fire synchronously inside
        // createTab — at which point our map is still empty.
        surfaces[tabId] = surface
        observeSurface(surface, forTab: tabId)
        focusSurface(for: tabId)
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
        guard let surface = note.object as? Ghostty.SurfaceView,
              surfaces.values.contains(where: { $0 === surface }),
              let focused = note.userInfo?["focused"] as? Bool,
              focused,
              let tabId = tabId(for: surface),
              let paneId = paneContaining(tabId: tabId) else { return }

        focusedOwnedSurface = surface

        let current = controller.focusedPaneId
        if current != paneId {
            controller.focusPane(paneId)
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
        surfaces.removeValue(forKey: tabId)
        surfaceSubscriptions.removeValue(forKey: tabId)
        updateWindowChromeTabId()

        if surfaces.isEmpty {
            // Defer the close to the next runloop tick so Bonsplit
            // finishes its own bookkeeping before the window goes away.
            DispatchQueue.main.async { [weak self] in
                self?.window?.performClose(nil)
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
        DispatchQueue.main.async { [weak self] in
            self?.focusCurrentTabSurface()
            self?.updateWindowChromeTabId()
        }
    }

    /// After Bonsplit creates the new pane from a split, populate it with
    /// a fresh ghostty surface using whatever config was stashed by the
    /// initiating `splitPane(from:direction:)` call.
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

        guard let tabId = newTab(inPane: newPane, baseConfig: cfg),
              let newSurface = surfaces[tabId] else { return }

        // Explicitly pass the source surface as `from` so its
        // `resignFirstResponder` fires reliably — AppKit sometimes
        // skips it in our setup, leaving the old pane visually focused.
        // For UI-originated splits (tab-bar split buttons) we don't have a
        // pending source from a ghostty action, so fall back to the most
        // recently focused owned surface.
        if let source, source !== newSurface {
            Ghostty.moveFocus(to: newSurface, from: source)
            focusedOwnedSurface = newSurface
        }
    }

    // didCreateTab intentionally NOT implemented: surfaces are only created
    // by `newTab()`, which focuses the surface itself after assigning it.
    // If Bonsplit ever creates tabs on its own (e.g. via a + button in the
    // tab bar), we'd need a different path for those.

    /// Focus the surface when the user switches tabs.
    func splitTabBar(
        _ controller: BonsplitController,
        didSelectTab tab: Tab,
        inPane pane: PaneID
    ) {
        // Defer one runloop tick so SwiftUI/AppKit finish any tab reparenting
        // first (notably drag-dropping a tab onto another pane's tab bar).
        DispatchQueue.main.async { [weak self] in
            self?.focusSurface(for: tab.id)
            self?.updateWindowChromeTabId()
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
        // Also push AppKit focus into the pane's selected surface.
        // This handles the case where the user clicks an already-selected
        // tab in another pane: didSelectTab doesn't fire (tab was already
        // selected), but we still need to move first-responder.
        focusCurrentTabSurface()
    }

    /// Move AppKit first-responder focus to this tab's surface.
    private func focusSurface(for tabId: TabID) {
        guard let surface = surfaces[tabId] else { return }

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
        guard let paneId = controller.focusedPaneId,
              let tab = controller.selectedTab(inPane: paneId) else { return }
        focusSurface(for: tab.id)
    }
}
