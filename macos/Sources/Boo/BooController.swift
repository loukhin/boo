import AppKit
import SwiftUI
import GhosttyKit

/// Step 1 Boo window controller.
///
/// Hosts a single `NSWindow` containing a SwiftUI `BooRootView` (which is built
/// around a `BonsplitView`). Mirrors the shape of `TerminalController.newWindow`
/// just enough to be a drop-in for the first-launch hook in `AppDelegate`.
///
/// This intentionally does NOT host any ghostty surfaces yet — that's step 2.
/// For now tabs contain a placeholder SwiftUI view so we can verify the
/// Bonsplit UI opens cleanly alongside (or instead of) a normal Ghostty
/// window.
final class BooController: NSWindowController {
    /// All live Boo controllers, so `AppDelegate` can check emptiness the
    /// same way it does for `TerminalController.all`.
    static private(set) var all: [BooController] = []

    let state: BooState

    // MARK: - Factory

    /// Open a new Boo window. Signature matches `TerminalController.newWindow`
    /// loosely so swap-in at the call site is a one-liner.
    @discardableResult
    static func newWindow(_ ghostty: Ghostty.App) -> BooController {
        let c = BooController(ghostty: ghostty)
        c.showWindow(nil)
        return c
    }

    // MARK: - Lifecycle

    init(ghostty: Ghostty.App) {
        self.state = BooState(ghostty: ghostty)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Boo"
        window.center()
        window.isReleasedWhenClosed = false

        let root = BooRootView(state: state)
        window.contentView = NSHostingView(rootView: root)

        super.init(window: window)

        // Let BooState know which window it lives in so it can filter
        // app-level ghostty notifications to the key window.
        state.window = window

        window.delegate = self
        BooController.all.append(self)
    }

    required init?(coder: NSCoder) {
        fatalError("BooController does not support NSCoder")
    }
}

// MARK: - NSWindowDelegate

extension BooController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        BooController.all.removeAll { $0 === self }
    }

    /// When the window becomes key, push focus into the current tab's
    /// surface so typing works without a click. Same pattern ghostty's
    /// `BaseTerminalController` uses.
    func windowDidBecomeKey(_ notification: Notification) {
        state.focusCurrentTabSurface()
    }
}
