import AppKit
import SwiftUI
import GhosttyKit
import Combine

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
final class BooController: NSWindowController, NSMenuItemValidation {
    /// All live Boo controllers, so `AppDelegate` can check emptiness the
    /// same way it does for `TerminalController.all`.
    static private(set) var all: [BooController] = []

    let state: BooState
    private let ghostty: Ghostty.App

    // MARK: - Factory

    /// Open a new Boo window. Signature matches `TerminalController.newWindow`
    /// loosely so swap-in at the call site is a one-liner.
    @discardableResult
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> BooController {
        let c = BooController(ghostty: ghostty, baseConfig: baseConfig)
        c.showWindow(nil)
        return c
    }

    /// Open a new Boo window adopting an existing surface (e.g., from drag-out).
    @discardableResult
    static func newWindow(
        _ ghostty: Ghostty.App,
        withSurface surface: Ghostty.SurfaceView,
        position: NSPoint? = nil
    ) -> BooController {
        let c = BooController(ghostty: ghostty, existingSurface: surface)
        c.showWindow(nil)
        if let position, let window = c.window {
            // Position window so the drop point is at the center of the window
            let windowSize = window.frame.size
            let origin = NSPoint(
                x: position.x - windowSize.width / 2,
                y: position.y - windowSize.height / 2
            )
            window.setFrameOrigin(origin)
            
            // Constrain to screen bounds
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(position) }) ?? NSScreen.main {
                var frame = window.frame
                let visibleFrame = screen.visibleFrame
                
                // Ensure window fits within screen
                if frame.maxX > visibleFrame.maxX {
                    frame.origin.x = visibleFrame.maxX - frame.width
                }
                if frame.minX < visibleFrame.minX {
                    frame.origin.x = visibleFrame.minX
                }
                if frame.maxY > visibleFrame.maxY {
                    frame.origin.y = visibleFrame.maxY - frame.height
                }
                if frame.minY < visibleFrame.minY {
                    frame.origin.y = visibleFrame.minY
                }
                
                window.setFrame(frame, display: true)
            }
            
            // Make the new window key so the old window properly resigns
            window.makeKeyAndOrderFront(nil)
        }
        return c
    }

    /// Create a new tab in an existing Boo window, or a new window if none exists.
    /// The `from` parameter identifies which window to add the tab to.
    @discardableResult
    static func newTab(
        _ ghostty: Ghostty.App,
        from window: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil
    ) -> BooController? {
        // Find a BooController to add the tab to
        let target: BooController? = {
            if let window,
               let controller = window.windowController as? BooController {
                return controller
            }
            // Prefer key window, then any existing controller
            if let key = NSApp.keyWindow?.windowController as? BooController {
                return key
            }
            return all.first
        }()

        if let target {
            target.state.newTab(baseConfig: baseConfig)
            return target
        } else {
            // No existing window, create a new one
            return newWindow(ghostty, withBaseConfig: baseConfig)
        }
    }

    // MARK: - Lifecycle

    init(ghostty: Ghostty.App, baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        self.ghostty = ghostty
        self.state = BooState(ghostty: ghostty, baseConfig: baseConfig)

        let window = Self.makeWindow()
        super.init(window: window)
        configureWindow()
    }

    /// Init with an existing surface (for drag-out-to-new-window).
    init(ghostty: Ghostty.App, existingSurface: Ghostty.SurfaceView) {
        self.ghostty = ghostty
        self.state = BooState(ghostty: ghostty, existingSurface: existingSurface)

        let window = Self.makeWindow()
        super.init(window: window)
        configureWindow()
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Boo"
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        return window
    }

    private func configureWindow() {
        guard let window else { return }

        let root = BooRootView(state: state)
        window.contentView = NSHostingView(rootView: root)

        // Apply initial window theme
        applyWindowTheme()

        // Let BooState know which window it lives in so it can filter
        // app-level ghostty notifications to the key window.
        state.window = window

        window.delegate = self
        BooController.all.append(self)

        // Listen for config changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )

        // Listen for fullscreen toggle from keybindings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onToggleFullscreen(_:)),
            name: Ghostty.Notification.ghosttyToggleFullscreen,
            object: nil
        )

        // Listen for close window from keybindings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onCloseWindow(_:)),
            name: .ghosttyCloseWindow,
            object: nil
        )

        // Listen for reset window size from keybindings
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onResetWindowSize(_:)),
            name: .ghosttyResetWindowSize,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("BooController does not support NSCoder")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Window Theming
    
    private func applyWindowTheme() {
        guard let window else { return }
        if let appearance = NSAppearance(ghosttyConfig: ghostty.config) {
            window.appearance = appearance
        }
        window.backgroundColor = NSColor(ghostty.config.backgroundColor)
    }
    
    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Delay slightly to ensure config values are updated
        DispatchQueue.main.async { [weak self] in
            self?.applyWindowTheme()
        }
    }
    
    @objc private func onToggleFullscreen(_ notification: Notification) {
        // Check if the notification is from a surface we own
        guard let surface = notification.object as? Ghostty.SurfaceView,
              state.surfaces.values.contains(where: { $0 === surface }) else { return }
        
        window?.toggleFullScreen(nil)
    }
    
    @objc private func onCloseWindow(_ notification: Notification) {
        // Check if the notification is from a surface we own
        guard let surface = notification.object as? Ghostty.SurfaceView,
              state.surfaces.values.contains(where: { $0 === surface }) else { return }
        
        window?.close()
    }
    
    @objc private func onResetWindowSize(_ notification: Notification) {
        // Check if the notification is from a surface we own
        guard let surface = notification.object as? Ghostty.SurfaceView,
              state.surfaces.values.contains(where: { $0 === surface }) else { return }
        
        // Reset to default size (900x600)
        guard let window else { return }
        let defaultSize = NSSize(width: 900, height: 600)
        let frame = NSRect(
            origin: window.frame.origin,
            size: defaultSize
        )
        window.setFrame(frame, display: true, animate: true)
    }
}

// MARK: - Menu Actions

extension BooController {
    @objc func newWindow(_ sender: Any?) {
        _ = BooController.newWindow(ghostty)
    }
    
    @objc func newTab(_ sender: Any?) {
        state.newTab()
    }
    
    @objc func closeTab(_ sender: Any?) {
        state.closeCurrentTab()
    }
    
    @objc func close(_ sender: Any?) {
        // Close current split pane, or tab if no splits
        state.closeCurrentPane()
    }
    
    @objc func closeWindow(_ sender: Any?) {
        window?.close()
    }
    
    @objc func splitRight(_ sender: Any?) {
        state.splitCurrentPane(direction: .right)
    }
    
    @objc func splitLeft(_ sender: Any?) {
        state.splitCurrentPane(direction: .left)
    }
    
    @objc func splitDown(_ sender: Any?) {
        state.splitCurrentPane(direction: .down)
    }
    
    @objc func splitUp(_ sender: Any?) {
        state.splitCurrentPane(direction: .up)
    }
    
    @objc func increaseFontSize(_ sender: Any?) {
        state.adjustFontSize(delta: 1)
    }
    
    @objc func decreaseFontSize(_ sender: Any?) {
        state.adjustFontSize(delta: -1)
    }
    
    @objc func resetFontSize(_ sender: Any?) {
        state.resetFontSize()
    }
    
    @objc func toggleGhosttyFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }
    
    // MARK: - Window Menu Split Actions
    
    @objc func splitZoom(_ sender: Any?) {
        // Boo doesn't support split zoom - no-op
    }
    
    @objc func splitMoveFocusPrevious(_ sender: Any?) {
        state.navigatePanes(direction: .previous)
    }
    
    @objc func splitMoveFocusNext(_ sender: Any?) {
        state.navigatePanes(direction: .next)
    }
    
    @objc func splitMoveFocusAbove(_ sender: Any?) {
        state.navigatePanes(direction: .up)
    }
    
    @objc func splitMoveFocusBelow(_ sender: Any?) {
        state.navigatePanes(direction: .down)
    }
    
    @objc func splitMoveFocusLeft(_ sender: Any?) {
        state.navigatePanes(direction: .left)
    }
    
    @objc func splitMoveFocusRight(_ sender: Any?) {
        state.navigatePanes(direction: .right)
    }
    
    @objc func equalizeSplits(_ sender: Any?) {
        // Boo doesn't support equalize splits - no-op
    }
    
    @objc func moveSplitDividerUp(_ sender: Any?) {
        // Boo doesn't support divider movement - no-op
    }
    
    @objc func moveSplitDividerDown(_ sender: Any?) {
        // Boo doesn't support divider movement - no-op
    }
    
    @objc func moveSplitDividerLeft(_ sender: Any?) {
        // Boo doesn't support divider movement - no-op
    }
    
    @objc func moveSplitDividerRight(_ sender: Any?) {
        // Boo doesn't support divider movement - no-op
    }
    
    // MARK: - Menu Validation
    
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(splitZoom(_:)),
             #selector(equalizeSplits(_:)),
             #selector(moveSplitDividerUp(_:)),
             #selector(moveSplitDividerDown(_:)),
             #selector(moveSplitDividerLeft(_:)),
             #selector(moveSplitDividerRight(_:)):
            // Disable unsupported split operations
            return false
        default:
            return true
        }
    }
}

// MARK: - NSWindowDelegate

extension BooController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        BooController.all.removeAll { $0 === self }
    }

    /// When the window becomes key, refocus the current surface so the
    /// cursor becomes filled again.
    func windowDidBecomeKey(_ notification: Notification) {
        state.setWindowKey(true)
        state.refocusCurrentSurface()
    }
    
    /// When the window loses key status, unfocus the surface so the cursor
    /// becomes hollow.
    func windowDidResignKey(_ notification: Notification) {
        state.setWindowKey(false)
        state.unfocusAllSurfaces()
    }
}


