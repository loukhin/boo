import Foundation
import SwiftUI
import GhosttyKit

// Bonsplit is vendored in macos/Sources/Bonsplit — same target, no import.

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

    private var tabCounter = 0

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty

        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            contentViewLifecycle: .keepAllAlive
        )
        self.controller = BonsplitController(configuration: config)
        self.controller.delegate = self

        subscribeToGhosttyNotifications()

        // Seed one initial tab so the window isn't empty on open.
        newTab()

        // Bonsplit seeds every new window with a default "Welcome" tab
        // (title "Welcome", icon "star"). There's no public config to
        // disable it, so we find and close it after creating our own
        // first tab. See bonsplitboo project for the original workaround.
        // If Bonsplit ever adds an option to suppress the welcome tab,
        // this can be removed.
        removeBonsplitWelcomeTab()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func removeBonsplitWelcomeTab() {
        for paneId in controller.allPaneIds {
            let tabs = controller.tabs(inPane: paneId)
            if let welcome = tabs.first(where: {
                $0.title == "Welcome" && $0.icon == "star"
            }) {
                _ = controller.closeTab(welcome.id)
                return
            }
        }
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
            icon: "terminal",
            inPane: paneId
        ) else { return nil }

        // We store the surface AFTER createTab returns (since Bonsplit
        // gives us the tabId then) and manually focus, because Bonsplit's
        // didCreateTab/didSelectTab hooks fire synchronously inside
        // createTab — at which point our map is still empty.
        surfaces[tabId] = surface
        focusSurface(for: tabId)
        return tabId
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
}

// MARK: - BonsplitDelegate

@MainActor
extension BooState: BonsplitDelegate {
    /// Free the surface when its tab is closed. Without this the surface
    /// (and its child process) would leak for the lifetime of the window.
    ///
    /// Also closes the enclosing window when the last surface goes away,
    /// which is what users expect when they `exit` the shell in the only
    /// tab of the only pane. Bonsplit leaves the pane visibly empty
    /// otherwise because `allowCloseLastPane` is false.
    func splitTabBar(
        _ controller: BonsplitController,
        didCloseTab tabId: TabID,
        fromPane pane: PaneID
    ) {
        surfaces.removeValue(forKey: tabId)

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
        let source = pendingSplitSource
        pendingSplitConfig = nil
        pendingSplitSource = nil

        guard let tabId = newTab(inPane: newPane, baseConfig: cfg),
              let newSurface = surfaces[tabId] else { return }

        // Explicitly pass the source surface as `from` so its
        // `resignFirstResponder` fires reliably — AppKit sometimes
        // skips it in our setup, leaving the old pane visually focused.
        // See ghostty's `Ghostty.moveFocus` comment about the same
        // workaround.
        if let source {
            Ghostty.moveFocus(to: newSurface, from: source)
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
        focusSurface(for: tab.id)
    }

    /// Move AppKit first-responder focus to this tab's surface.
    private func focusSurface(for tabId: TabID) {
        guard let surface = surfaces[tabId] else { return }
        Ghostty.moveFocus(to: surface)
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
