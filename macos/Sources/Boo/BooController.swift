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
    private let restorable: Bool
    private var keyDownMonitor: Any?
    private var isBackgroundOpaque = false

    override var undoManager: ExpiringUndoManager? {
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    private var undoExpiration: Duration {
        ghostty.config.undoTimeout
    }

    private struct WindowUndoState {
        let frame: NSRect
        let state: BooRestorableState
    }

    private var undoState: WindowUndoState? {
        guard let window, !state.surfaces.isEmpty else { return nil }
        return WindowUndoState(
            frame: window.frame,
            state: BooRestorableState(from: state)
        )
    }

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
        if let window = c.window, !window.styleMask.contains(.fullScreen) {
            let initialContentSize = BooWindowSizing.initialContentSize(
                from: c.state,
                fallbackToCurrentSurfaceSize: false
            )
            BooWindowSizing.applyCascade(
                to: window,
                initialContentSize: initialContentSize,
                windowCount: all.count
            )
            if initialContentSize == nil {
                c.retryApplyInitialBooContentSize()
            }
        }
        c.registerNewWindowUndo(baseConfig: baseConfig)
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
        if let window = c.window, !window.styleMask.contains(.fullScreen),
           let initialContentSize = BooWindowSizing.initialContentSize(
               from: c.state,
               fallbackToCurrentSurfaceSize: true
           ) {
            window.setContentSize(initialContentSize)
            window.constrainToScreen()
        }
        if let position, let window = c.window {
            BooWindowSizing.centerWindow(window, at: position)

            // Make the new window key so the old window properly resigns
            window.makeKeyAndOrderFront(nil)
        }
        c.registerNewWindowUndo(adopting: surface, position: position)
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

    static func closeAllWindows() {
        let controllers = all
        guard !controllers.isEmpty else { return }

        guard let confirmWindow = controllers
            .first(where: { controller in
                controller.state.surfaces.values.contains { surface in
                    surface.needsConfirmQuit
                }
            })?
            .window
        else {
            closeAllWindowsImmediately(controllers)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow) { response in
            if response == .alertFirstButtonReturn {
                alert.window.orderOut(nil)
                closeAllWindowsImmediately(controllers)
            }
        }
    }

    private static func closeAllWindowsImmediately(_ controllers: [BooController]) {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        for controller in controllers where controller.window != nil {
            controller.closeWindowImmediately()
        }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    private static func restoreWindow(
        _ ghostty: Ghostty.App,
        from undoState: WindowUndoState
    ) -> BooController {
        let controller = BooController(ghostty: ghostty, restorableState: undoState.state)
        controller.showWindow(nil)
        if let window = controller.window {
            window.setFrame(undoState.frame, display: true)
            window.makeKeyAndOrderFront(nil)
        }
        controller.state.restoreFocus(toSurfaceWithId: undoState.state.focusedSurfaceId)
        return controller
    }

    private func registerNewWindowUndo(baseConfig: Ghostty.SurfaceConfiguration?) {
        registerNewWindowUndo {
            _ = BooController.newWindow($0, withBaseConfig: baseConfig)
        }
    }

    private func registerNewWindowUndo(
        adopting surface: Ghostty.SurfaceView,
        position: NSPoint?
    ) {
        registerNewWindowUndo {
            _ = BooController.newWindow($0, withSurface: surface, position: position)
        }
    }

    private func registerNewWindowUndo(
        redo: @escaping (Ghostty.App) -> Void
    ) {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        undoManager.setActionName("New Window")
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            undoManager.disableUndoRegistration {
                target.closeWindowImmediately(registerUndo: false)
            }

            undoManager.registerUndo(
                withTarget: target.ghostty,
                expiresAfter: target.undoExpiration
            ) { ghostty in
                redo(ghostty)
            }
        }
    }

    func closeWindowImmediately(registerUndo: Bool = true) {
        let snapshot = undoState

        if registerUndo,
           let undoManager,
           undoManager.isUndoRegistrationEnabled,
           let snapshot {
            undoManager.setActionName("Close Window")
            undoManager.registerUndo(
                withTarget: ghostty,
                expiresAfter: undoExpiration
            ) { ghostty in
                let restored = BooController.restoreWindow(ghostty, from: snapshot)
                undoManager.registerUndo(
                    withTarget: restored,
                    expiresAfter: restored.undoExpiration
                ) { target in
                    target.closeWindowImmediately()
                }
            }
        }

        for surface in state.surfaces.values {
            surface.focusDidChange(false)
            surface.cachedScrollView = nil
        }
        window?.close()
    }

    // MARK: - Lifecycle

    init(ghostty: Ghostty.App, baseConfig: Ghostty.SurfaceConfiguration? = nil) {
        self.ghostty = ghostty
        self.restorable = (baseConfig?.command ?? "").isEmpty
        self.state = BooState(ghostty: ghostty, baseConfig: baseConfig)

        let window = Self.makeWindow()
        super.init(window: window)
        configureWindow()
    }

    /// Init with an existing surface (for drag-out-to-new-window).
    init(ghostty: Ghostty.App, existingSurface: Ghostty.SurfaceView) {
        self.ghostty = ghostty
        self.restorable = true
        self.state = BooState(ghostty: ghostty, existingSurface: existingSurface)

        let window = Self.makeWindow()
        super.init(window: window)
        configureWindow()
    }

    /// Init from AppKit restoration state.
    init(ghostty: Ghostty.App, restorableState: BooRestorableState) {
        self.ghostty = ghostty
        self.restorable = true
        self.state = BooState(ghostty: ghostty, restorableState: restorableState)

        let window = Self.makeWindow()
        super.init(window: window)
        configureWindow()
    }

    private func retryApplyInitialBooContentSize(attempt: Int = 0) {
        guard attempt < 5,
              let window,
              !window.styleMask.contains(.fullScreen) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard let self, let window else { return }
            if let size = BooWindowSizing.initialContentSize(
                from: self.state,
                fallbackToCurrentSurfaceSize: false
            ) {
                window.setContentSize(size)
                window.constrainToScreen()
            } else {
                self.retryApplyInitialBooContentSize(attempt: attempt + 1)
            }
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Boo"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.collectionBehavior = [.fullScreenPrimary]
        return window
    }

    private func configureWindow() {
        guard let window else { return }

        // NSWindow caches its undo manager the first time `window.undoManager`
        // is read. Attach the delegate before SwiftUI/content installation so
        // any early undo-manager lookup gets AppDelegate's ExpiringUndoManager
        // via `windowWillReturnUndoManager(_:)` instead of a private default.
        window.delegate = self

        let root = BooRootView(state: state)
        window.contentView = NSHostingView(rootView: root)

        // Set autosave name AFTER content view to prevent SwiftUI override.
        window.setFrameAutosaveName("BooWindow")

        window.isRestorable = restorable
        if restorable {
            window.restorationClass = BooWindowRestoration.self
            window.identifier = BooWindowRestoration.restorationIdentifier
        }

        // Apply initial window theme
        applyWindowTheme()

        if window.styleMask.contains(.titled) {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .left
            accessory.view = NonDraggableHostingView(
                rootView: BooTitlebarWorkspaceControls(state: state)
            )
            window.addTitlebarAccessoryViewController(accessory)
            accessory.view.translatesAutoresizingMaskIntoConstraints = false
        }

        if window.styleMask.contains(.titled),
           let appDelegate = NSApp.delegate as? AppDelegate {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            accessory.view = NonDraggableHostingView(
                rootView: BooUpdateAccessoryView(model: appDelegate.updateViewModel)
            )
            window.addTitlebarAccessoryViewController(accessory)
            accessory.view.translatesAutoresizingMaskIntoConstraints = false
        }

        // In non-release builds, install a right-aligned titlebar pill so
        // the "this is a debug build" signal is present without stealing a
        // row of terminal content. Same gate the old inline banner used.
        //
        // NOTE on ordering: `translatesAutoresizingMaskIntoConstraints = false`
        // must be set AFTER `addTitlebarAccessoryViewController`, matching the
        // pattern in `TerminalWindow.awakeFromNib`. Setting it earlier means
        // AppKit never synthesizes placement constraints from the hosting view's
        // frame and the pill ends up with a 0x0 layout.
        if window.styleMask.contains(.titled),
           Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG ||
           Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE {
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            // `NonDraggableHostingView` so clicking the pill doesn't start
            // a window drag (same reason ghostty uses it for the update pill).
            accessory.view = NonDraggableHostingView(rootView: BooDebugAccessoryView())
            window.addTitlebarAccessoryViewController(accessory)
            accessory.view.translatesAutoresizingMaskIntoConstraints = false
        }

        // Let BooState know which window it lives in so it can filter
        // app-level ghostty notifications to the key window.
        state.window = window
        state.syncWindowChromeToWindow()

        BooController.all.append(self)

        // Listen for config changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChange(_:)),
            name: .ghosttyConfigDidChange,
            object: nil
        )

        // Save window frame on app termination (Cmd+Q)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // App activation can preserve the same key window/first responder,
        // so NSWindow.didBecomeKey is not always enough to restore terminal
        // cursor visuals after we marked surfaces unfocused on deactivate.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
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

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  self.window?.isKeyWindow == true,
                  self.handleBooKeyDown(event) else { return event }
            return nil
        }
    }

    required init?(coder: NSCoder) {
        fatalError("BooController does not support NSCoder")
    }

    deinit {
        undoManager?.removeAllActions(withTarget: self)
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window Theming

    private func applyWindowTheme() {
        guard let window else { return }
        window.appearance = NSAppearance(ghosttyConfig: ghostty.config)

        let backgroundColor = NSColor(ghostty.config.backgroundColor).usingColorSpace(.sRGB)
            ?? NSColor.windowBackgroundColor
        let chromeBackgroundColor = BooChromeColors.chromeBackgroundColor(from: backgroundColor)
        let canUseTransparency = !window.styleMask.contains(.fullScreen)
            && !isBackgroundOpaque
            && (ghostty.config.backgroundOpacity < 1 || ghostty.config.backgroundBlur.isGlassStyle)

        if canUseTransparency {
            window.isOpaque = false
            window.backgroundColor = .white.withAlphaComponent(0.001)

            if !ghostty.config.backgroundBlur.isGlassStyle {
                ghostty_set_window_background_blur(
                    ghostty.app,
                    Unmanaged.passUnretained(window).toOpaque()
                )
            }
        } else {
            window.isOpaque = true
            window.backgroundColor = chromeBackgroundColor.withAlphaComponent(1)
        }

        applyTitlebarBackground(color: chromeBackgroundColor)
    }

    private func applyTitlebarBackground(color: NSColor) {
        guard let titlebarContainer else { return }
        let opacity = isBackgroundOpaque ? 1 : max(0.001, BooChromeColors.clampedBackgroundOpacity(for: ghostty.config))
        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = color.withAlphaComponent(opacity).cgColor
    }

    private var titlebarContainer: NSView? {
        if window?.styleMask.contains(.fullScreen) != true {
            return window?.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        for candidate in NSApplication.shared.windows {
            guard candidate.className == "NSToolbarFullScreenWindow",
                  candidate.parent == window else { continue }
            return candidate.contentView?.firstViewFromRoot(withClassName: "NSTitlebarContainerView")
        }

        return nil
    }

    func toggleBackgroundOpacity() {
        guard ghostty.config.backgroundOpacity < 1 else { return }
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        isBackgroundOpaque.toggle()
        applyWindowTheme()
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

        // Use performClose so `windowShouldClose` runs and we can prompt
        // for confirmation if any surface in the window still has a
        // running child process.
        window?.performClose(nil)
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

    @objc private func applicationWillTerminate(_ notification: Notification) {
        // Explicitly save all window frames on quit.
        // setFrameAutosaveName auto-saves on move/resize, but not guaranteed on quit.
        for controller in BooController.all {
            controller.window?.saveFrame(usingName: "BooWindow")
        }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        state.setWindowKey(true)
        state.refocusCurrentSurface()
    }

    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard window?.isKeyWindow == true else { return }
        state.setWindowKey(false)
        state.unfocusAllSurfaces()
    }

    private func handleBooKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])

        // Leave ⌘1–⌘9 alone so Ghostty's normal `goto_tab` keybindings keep
        // owning tab selection. Boo only claims the workspace-specific layer:
        // Control plus a number switches workspaces.
        if flags == [.control], let index = Self.numberShortcutIndex(for: event) {
            state.switchToWorkspace(at: index)
            return true
        }

        if flags == [.command], Self.isKey(event, characters: "s", keyCode: 0x01) {
            state.toggleWorkspaceSidebar()
            return true
        }

        if flags == [.command], Self.isKey(event, characters: "n", keyCode: 0x2D) {
            state.newWorkspace(
                baseConfig: state.inheritedConfigForFocusedSurface(
                    context: GHOSTTY_SURFACE_CONTEXT_WINDOW
                )
            )
            return true
        }

        if flags == [.command, .shift], Self.isKey(event, characters: "n", keyCode: 0x2D) {
            _ = BooController.newWindow(
                ghostty,
                withBaseConfig: state.inheritedConfigForFocusedSurface(
                    context: GHOSTTY_SURFACE_CONTEXT_WINDOW
                )
            )
            return true
        }

        return false
    }

    private static func numberShortcutIndex(for event: NSEvent) -> Int? {
        if let key = event.charactersIgnoringModifiers,
           key.count == 1,
           let value = Int(key),
           (1...9).contains(value) {
            return value - 1
        }

        switch event.keyCode {
        case 0x12: return 0 // ANSI 1
        case 0x13: return 1 // ANSI 2
        case 0x14: return 2 // ANSI 3
        case 0x15: return 3 // ANSI 4
        case 0x17: return 4 // ANSI 5
        case 0x16: return 5 // ANSI 6
        case 0x1A: return 6 // ANSI 7
        case 0x1C: return 7 // ANSI 8
        case 0x19: return 8 // ANSI 9
        case 0x53: return 0 // Keypad 1
        case 0x54: return 1 // Keypad 2
        case 0x55: return 2 // Keypad 3
        case 0x56: return 3 // Keypad 4
        case 0x57: return 4 // Keypad 5
        case 0x58: return 5 // Keypad 6
        case 0x59: return 6 // Keypad 7
        case 0x5B: return 7 // Keypad 8
        case 0x5C: return 8 // Keypad 9
        default: return nil
        }
    }

    private static func isKey(_ event: NSEvent, characters: String, keyCode: UInt16) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == characters || event.keyCode == keyCode
    }
}

private struct BooTitlebarWorkspaceControls: View {
    @ObservedObject var state: BooState

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Button {
                state.toggleWorkspaceSidebar()
            } label: {
                titlebarIcon("sidebar.left")
            }
            .buttonStyle(.plain)
            .help("Toggle Workspace Sidebar")

            Button {
                state.newWorkspace(
                    baseConfig: state.inheritedConfigForFocusedSurface(
                        context: GHOSTTY_SURFACE_CONTEXT_WINDOW
                    )
                )
            } label: {
                titlebarIcon("plus")
            }
            .buttonStyle(.plain)
            .help("New Workspace")

            BooProxyTitleView(
                title: state.windowChromeTitle,
                url: state.windowChromeURL
            )
            .frame(height: 20)
            .padding(.leading, 4)
        }
        .frame(height: 28, alignment: .center)
        .padding(.leading, 8)
        // AppKit places titlebar accessories slightly high relative to the
        // traffic lights. Nudge the whole cluster down so the symbols sit on
        // the same optical centerline.
        .offset(y: 2)
    }

    private func titlebarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20, alignment: .center)
            .contentShape(Rectangle())
    }
}

private struct BooProxyTitleView: NSViewRepresentable {
    let title: String
    let url: URL?

    func makeNSView(context: Context) -> BooProxyTitleNSView {
        BooProxyTitleNSView()
    }

    func updateNSView(_ view: BooProxyTitleNSView, context: Context) {
        view.title = title
        view.representedURL = url
    }
}

private final class BooProxyTitleNSView: NSView, NSDraggingSource {
    var title: String = "Boo" {
        didSet { updateTitle() }
    }

    var representedURL: URL? {
        didSet { updateIcon() }
    }

    private let stackView = NSStackView()
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "Boo")
    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        let textSize = titleField.intrinsicContentSize
        let iconWidth: CGFloat = representedURL == nil ? 0 : 21
        return NSSize(width: min(360, iconWidth + textSize.width), height: 20)
    }

    override func rightMouseDown(with event: NSEvent) {
        showPathMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control])
        if !flags.isEmpty {
            showPathMenu(with: event)
            return
        }

        guard representedURL != nil else { return }
        mouseDownEvent = event
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent, !didStartDrag else { return }

        let start = mouseDownEvent.locationInWindow
        let current = event.locationInWindow
        let distance = hypot(current.x - start.x, current.y - start.y)
        guard distance >= 3 else { return }

        didStartDrag = true
        startDragging(with: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
        didStartDrag = false
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func setupView() {
        wantsLayer = true

        imageView.imageScaling = .scaleProportionallyDown
        imageView.setContentHuggingPriority(.required, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.required, for: .horizontal)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 5
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleField)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        updateTitle()
        updateIcon()
    }

    private func updateTitle() {
        titleField.stringValue = title
        invalidateIntrinsicContentSize()
    }

    private func updateIcon() {
        guard let representedURL else {
            imageView.image = nil
            imageView.isHidden = true
            invalidateIntrinsicContentSize()
            return
        }

        let image = NSWorkspace.shared.icon(forFile: representedURL.path)
        image.size = NSSize(width: 16, height: 16)
        imageView.image = image
        imageView.isHidden = false
        invalidateIntrinsicContentSize()
    }

    private func showPathMenu(with event: NSEvent) {
        guard let representedURL else { return }

        let menu = NSMenu()
        for url in pathMenuURLs(from: representedURL) {
            let item = NSMenuItem(
                title: menuTitle(for: url),
                action: #selector(openPathMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = url
            item.image = menuIcon(for: url)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let copyItem = NSMenuItem(
            title: "Copy Path",
            action: #selector(copyPathMenuItem(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.representedObject = representedURL
        menu.addItem(copyItem)

        menu.popUp(positioning: nil, at: proxyMenuPoint, in: self)
    }

    private var proxyMenuPoint: NSPoint {
        guard representedURL != nil else { return .zero }

        let iconFrame = imageView.convert(imageView.bounds, to: self)
        return NSPoint(
            x: iconFrame.minX,
            y: iconFrame.minY - 2
        )
    }

    private func pathMenuURLs(from url: URL) -> [URL] {
        var urls: [URL] = []
        var current = url.standardizedFileURL
        var seenPaths: Set<String> = []

        while !seenPaths.contains(current.path) {
            urls.append(current)
            seenPaths.insert(current.path)

            let parent = current.deletingLastPathComponent().standardizedFileURL
            guard parent.path != current.path else { break }
            current = parent
        }

        return urls
    }

    private func menuTitle(for url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        if !name.isEmpty { return name }
        return url.path
    }

    private func menuIcon(for url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func openPathMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyPathMenuItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    private func startDragging(with event: NSEvent) {
        guard let representedURL else { return }

        let draggingItem = NSDraggingItem(pasteboardWriter: representedURL as NSURL)
        let image = dragImage(for: representedURL)
        let location = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(
            NSRect(
                x: location.x - image.size.width / 2,
                y: location.y - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            ),
            contents: image
        )

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func dragImage(for url: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)

        let displayTitle = title.isEmpty ? menuTitle(for: url) : title
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let attributedTitle = NSAttributedString(string: displayTitle, attributes: attributes)
        let textSize = attributedTitle.size()
        let textWidth = min(320, ceil(textSize.width))
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 4
        let spacing: CGFloat = 5
        let iconSize = NSSize(width: 16, height: 16)
        let imageSize = NSSize(
            width: paddingX * 2 + iconSize.width + spacing + textWidth,
            height: paddingY * 2 + max(iconSize.height, ceil(textSize.height))
        )

        let image = NSImage(size: imageSize)
        image.lockFocus()

        let iconRect = NSRect(
            x: paddingX,
            y: (imageSize.height - iconSize.height) / 2,
            width: iconSize.width,
            height: iconSize.height
        )
        icon.draw(in: iconRect)

        let textRect = NSRect(
            x: iconRect.maxX + spacing,
            y: (imageSize.height - textSize.height) / 2,
            width: textWidth,
            height: textSize.height
        )
        attributedTitle.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        image.unlockFocus()
        return image
    }
}

// MARK: - Menu Actions

extension BooController {
    @objc func newWindow(_ sender: Any?) {
        state.newWorkspace(
            baseConfig: state.inheritedConfigForFocusedSurface(
                context: GHOSTTY_SURFACE_CONTEXT_WINDOW
            )
        )
    }

    @objc func newTab(_ sender: Any?) {
        state.newTab(
            baseConfig: state.inheritedConfigForFocusedSurface(
                context: GHOSTTY_SURFACE_CONTEXT_TAB
            )
        )
    }

    @objc func closeTab(_ sender: Any?) {
        state.closeCurrentTab()
    }

    @objc func close(_ sender: Any?) {
        // Close current split pane, or tab if no splits
        state.closeCurrentPane()
    }

    @objc func closeWindow(_ sender: Any?) {
        window?.performClose(nil)
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
    /// Called when the user clicks the red window X or anything else that
    /// goes through `performClose`. Prompts for confirmation when any
    /// surface in the window still has a running child process.
    ///
    /// Direct `window.close()` bypasses this delegate (AppKit behavior),
    /// which is why we route the keybind-driven close through `performClose`.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // No surfaces means nothing to confirm or undo - let the close proceed.
        if state.surfaces.isEmpty { return true }

        let close: () -> Void = { [weak self] in
            self?.closeWindowImmediately()
        }

        // If nothing in the window needs confirmation, close immediately so
        // the undo snapshot is captured before AppKit tears the window down.
        let needsConfirm = state.surfaces.values.contains { $0.needsConfirmQuit }
        if !needsConfirm {
            close()
            return false
        }

        state.presentCloseConfirmation(
            messageText: "Close Window?",
            informativeText: "All terminals in this window will be closed. Any running processes will be killed.",
            onConfirm: close
        )
        return false
    }

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        guard restorable else { return }
        BooRestorableState(from: self.state).encode(with: state)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        BooController.all.removeAll { $0 === self }

        // Update cascade point like Ghostty does so the next window
        // cascades from the remaining key window.
        BooWindowSizing.updateCascadePoint(closing: window)
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

    func windowDidDeminiaturize(_ notification: Notification) {
        state.setWindowKey(window?.isKeyWindow == true)
        state.refocusCurrentSurface()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        applyWindowTheme()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        applyWindowTheme()
    }
}

/// Applies the same top/trailing padding Ghostty uses for its right-aligned
/// update titlebar accessory.
private struct BooUpdateAccessoryView: View {
    @ObservedObject var model: UpdateViewModel

    private var topPadding: CGFloat {
        if #available(macOS 26.0, *) { 5 } else { 4 }
    }

    var body: some View {
        UpdatePill(model: model)
            .padding(.top, topPadding)
            .padding(.trailing, topPadding)
    }
}

