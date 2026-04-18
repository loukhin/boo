import Foundation
import SwiftUI
import Bonsplit
import GhosttyKit

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
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Tab ops

    /// Create a new Bonsplit tab and spawn a fresh ghostty surface into it.
    @discardableResult
    func newTab(baseConfig: Ghostty.SurfaceConfiguration? = nil) -> TabID? {
        guard let app = ghostty.app else { return nil }

        tabCounter += 1
        let surface = Ghostty.SurfaceView(app, baseConfig: baseConfig)

        guard let tabId = controller.createTab(
            title: "Terminal",
            icon: "terminal"
        ) else { return nil }

        // Assign the surface BEFORE any delegate callbacks run. Bonsplit
        // fires didCreateTab / didSelectTab synchronously inside
        // `createTab`, so if we assigned after it, those callbacks would
        // see an empty surfaces map.
        //
        // NOTE: Bonsplit's createTab currently returns AFTER the sync
        // callbacks fire, which means this line still runs too late for
        // the delegate hooks. We focus manually here instead.
        surfaces[tabId] = surface
        focusSurface(for: tabId)
        return tabId
    }

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
    func splitTabBar(
        _ controller: BonsplitController,
        didCloseTab tabId: TabID,
        fromPane pane: PaneID
    ) {
        surfaces.removeValue(forKey: tabId)
    }

    // didCreateTab intentionally NOT implemented: surfaces are only created
    // by `newTab()`, which focuses the surface itself after assigning it.
    // If Bonsplit ever creates tabs on its own (e.g. via a + button in the
    // tab bar), we'd need a different path for those.

    /// Focus the surface when the user switches tabs.
    func splitTabBar(
        _ controller: BonsplitController,
        didSelectTab tab: Bonsplit.Tab,
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
