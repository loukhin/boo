import AppKit
import GhosttyKit

/// Boo-specific window sizing policy.
///
/// Ghostty config sizes describe the terminal surface. Boo adds fixed Bonsplit
/// chrome height, but intentionally excludes toggleable workspace sidebar width.
@MainActor
enum BooWindowSizing {
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    static func initialContentSize(
        from state: BooState,
        fallbackToCurrentSurfaceSize: Bool
    ) -> NSSize? {
        guard let surface = state.surfaces.values.first else { return nil }

        if let initialSize = surface.initialSize {
            return contentSize(forTerminalSurfaceSize: initialSize)
        }

        guard fallbackToCurrentSurfaceSize,
              surface.frame.width > 0,
              surface.frame.height > 0 else { return nil }
        return contentSize(forTerminalSurfaceSize: surface.frame.size)
    }

    static func contentSize(forTerminalSurfaceSize size: NSSize) -> NSSize {
        NSSize(
            width: size.width,
            height: size.height + TabBarMetrics.barHeight
        )
    }

    static func applyCascade(
        to window: NSWindow,
        initialContentSize: NSSize? = nil,
        windowCount: Int
    ) {
        // Apply initial size from ghostty config if provided. In Boo, the
        // config size means terminal surface size; we add fixed Bonsplit
        // chrome before getting here but intentionally exclude sidebar width.
        if let size = initialContentSize {
            window.setContentSize(size)
            window.constrainToScreen()
        }

        if windowCount > 1 {
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

    static func centerWindow(_ window: NSWindow, at point: NSPoint) {
        let windowSize = window.frame.size
        let origin = NSPoint(
            x: point.x - windowSize.width / 2,
            y: point.y - windowSize.height / 2
        )
        window.setFrameOrigin(origin)
        constrain(window, around: point)
    }

    static func constrain(_ window: NSWindow, around point: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else {
            return
        }

        var frame = window.frame
        let visibleFrame = screen.visibleFrame

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

    static func updateCascadePoint(closing window: NSWindow?) {
        if let focusedWindow = NSApplication.shared.keyWindow {
            if focusedWindow != window {
                // Closing a non-key window: cascade from the key window.
                // Save and restore frame to avoid macOS 15 window snapping issues.
                let oldFrame = focusedWindow.frame
                lastCascadePoint = focusedWindow.cascadeTopLeft(from: .zero)
                if focusedWindow.frame != oldFrame {
                    focusedWindow.setFrame(oldFrame, display: true)
                }
            } else {
                // Closing the key window: use its position for next window.
                let frame = focusedWindow.frame
                lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
            }
        }
    }

    private static func restoreFrameOriginOnly(for window: NSWindow, autosaveName: String) -> Bool {
        let size = window.frame.size
        guard window.setFrameUsingName(autosaveName) else { return false }
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: true)
        return true
    }
}
