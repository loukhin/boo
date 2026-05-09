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
    private var keyDownMonitor: Any?

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
            let initialContentSize = c.initialBooContentSize(fallbackToCurrentSurfaceSize: false)
            applyCascade(to: window, initialContentSize: initialContentSize)
            if initialContentSize == nil {
                c.retryApplyInitialBooContentSize()
            }
        }
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
           let initialContentSize = c.initialBooContentSize(fallbackToCurrentSurfaceSize: true) {
            window.setContentSize(initialContentSize)
            window.constrainToScreen()
        }
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

    // Track cascade point for positioning new windows, like Ghostty does.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, initialContentSize: NSSize? = nil) {
        // Apply initial size from ghostty config if provided. In Boo, the
        // config size means terminal surface size; we add fixed Bonsplit
        // chrome before getting here but intentionally exclude sidebar width.
        if let size = initialContentSize {
            window.setContentSize(size)
            window.constrainToScreen()
        }

        if all.count > 1 {
            // Cascade from last cascade point (matches Ghostty behavior).
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // First window: try to restore saved position, otherwise center.
            // If config supplied a size, don't restore the previous size over
            // it; matching Ghostty, config/default size wins over saved size.
            let restored: Bool
            if initialContentSize == nil {
                restored = window.setFrameUsingName("BooWindow")
            } else {
                restored = restoreFrameOriginOnly(for: window, autosaveName: "BooWindow")
            }
            if !restored {
                window.center()
            }
            // Get cascade point. For restored windows, save frame first since
            // cascadeTopLeft(from: .zero) might move it on some macOS versions.
            let savedFrame = window.frame
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
            if restored && window.frame != savedFrame {
                window.setFrame(savedFrame, display: true)
            }
        }
    }

    private func initialBooContentSize(fallbackToCurrentSurfaceSize: Bool) -> NSSize? {
        guard let surface = state.surfaces.values.first else { return nil }

        if let initialSize = surface.initialSize {
            return Self.booContentSize(forTerminalSurfaceSize: initialSize)
        }

        guard fallbackToCurrentSurfaceSize,
              surface.frame.width > 0,
              surface.frame.height > 0 else { return nil }
        return Self.booContentSize(forTerminalSurfaceSize: surface.frame.size)
    }

    private func retryApplyInitialBooContentSize(attempt: Int = 0) {
        guard attempt < 5,
              let window,
              !window.styleMask.contains(.fullScreen) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak window] in
            guard let self, let window else { return }
            if let size = self.initialBooContentSize(fallbackToCurrentSurfaceSize: false) {
                window.setContentSize(size)
                window.constrainToScreen()
            } else {
                self.retryApplyInitialBooContentSize(attempt: attempt + 1)
            }
        }
    }

    private static func booContentSize(forTerminalSurfaceSize size: NSSize) -> NSSize {
        NSSize(
            width: size.width,
            height: size.height + TabBarMetrics.barHeight
        )
    }

    private static func restoreFrameOriginOnly(for window: NSWindow, autosaveName: String) -> Bool {
        let size = window.frame.size
        guard window.setFrameUsingName(autosaveName) else { return false }
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: true)
        return true
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

        let root = BooRootView(state: state)
        window.contentView = NSHostingView(rootView: root)

        // Set autosave name AFTER content view to prevent SwiftUI override.
        window.setFrameAutosaveName("BooWindow")

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

        window.delegate = self
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
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
        }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window Theming

    private func applyWindowTheme() {
        guard let window else { return }
        if let appearance = NSAppearance(ghosttyConfig: ghostty.config) {
            window.appearance = appearance
        }
        window.backgroundColor = NSColor(ghostty.config.backgroundColor).usingColorSpace(.sRGB)
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

    private func handleBooKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }

        if flags == [.command], let index = Self.workspaceShortcutIndex(for: key) {
            state.switchToWorkspace(at: index)
            return true
        }

        if flags == [.control], let index = Self.workspaceShortcutIndex(for: key) {
            state.selectTab(at: index)
            return true
        }

        if flags == [.command], key == "s" {
            state.toggleWorkspaceSidebar()
            return true
        }

        if flags == [.command], key == "n" {
            state.newWorkspace(
                baseConfig: state.inheritedConfigForFocusedSurface(
                    context: GHOSTTY_SURFACE_CONTEXT_WINDOW
                )
            )
            return true
        }

        if flags == [.command, .shift], key == "n" {
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

    private static func workspaceShortcutIndex(for key: String) -> Int? {
        guard key.count == 1, let value = Int(key), (1...9).contains(value) else { return nil }
        return value - 1
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
        // No surfaces means nothing to confirm - let the close proceed.
        if state.surfaces.isEmpty { return true }

        // If nothing in the window needs confirmation, close immediately.
        let needsConfirm = state.surfaces.values.contains { $0.needsConfirmQuit }
        if !needsConfirm { return true }

        state.presentCloseConfirmation(
            messageText: "Close Window?",
            informativeText: "All terminals in this window will be closed. Any running processes will be killed."
        ) { [weak sender] in
            sender?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        BooController.all.removeAll { $0 === self }

        // Update cascade point like Ghostty does so the next window
        // cascades from the remaining key window.
        if let focusedWindow = NSApplication.shared.keyWindow {
            if focusedWindow != window {
                // Closing a non-key window: cascade from the key window.
                // Save and restore frame to avoid macOS 15 window snapping issues.
                let oldFrame = focusedWindow.frame
                Self.lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)
                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }
            } else {
                // Closing the key window: use its position for next window.
                let frame = focusedWindow.frame
                Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
            }
        }
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


