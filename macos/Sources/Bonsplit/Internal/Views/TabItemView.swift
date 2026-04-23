import AppKit
import SwiftUI

/// Individual tab view with icon, title, close button, and dirty indicator
struct TabItemView: View {
    let tab: TabItem
    let isSelected: Bool
    /// Whether the owning pane is currently active (focused or drag source).
    /// When false, the accent indicator desaturates to signal the unfocused
    /// state without affecting the selected-tab background fill.
    var isPaneActive: Bool = true
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.terminalBackgroundColor) private var backgroundColor
    @State private var isHovered = false
    @State private var isCloseHovered = false

    var body: some View {
        HStack(spacing: TabBarMetrics.contentSpacing) {
            // Icon
            if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: TabBarMetrics.iconSize))
                    .foregroundStyle(isSelected ? TabBarColors.activeText : TabBarColors.inactiveText)
            }

            // Title. Constrained directly so the tab hugs its content
            // instead of padding the space between title and close button
            // out to `tabMaxWidth`. Long titles still truncate at the
            // title-level max; short titles produce a naturally compact tab.
            Text(tab.title)
                .font(.system(size: TabBarMetrics.titleFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: TabBarMetrics.tabTitleMaxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(isSelected ? TabBarColors.activeText : TabBarColors.inactiveText)

            // Close button or dirty indicator
            closeOrDirtyIndicator
        }
        // Asymmetric padding: full horizontal padding on the leading side
        // (for the icon/title), tighter on the trailing side so the close
        // button sits closer to the edge and the tab feels more compact.
        .padding(.leading, TabBarMetrics.tabHorizontalPadding)
        .padding(.trailing, TabBarMetrics.tabTrailingPadding)
        .offset(y: isSelected ? 0.5 : 0)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            minHeight: TabBarMetrics.tabHeight,
            maxHeight: TabBarMetrics.tabHeight
        )
        .padding(.bottom, isSelected ? 1 : 0)
        .background(tabBackground)
        .contentShape(Rectangle())
        // Middle-click closes the tab. Overlaid as an AppKit view so we can
        // pick up `otherMouseUp` without stealing left/right clicks from the
        // SwiftUI tap/drag gestures below.
        .overlay(MiddleClickCloseView(onMiddleClick: onClose))
        // Selected tab covers the tab bar's bottom border
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(backgroundColor)
                    .frame(height: 2)
                    .offset(y: 1)
            }
        }
        .zIndex(isSelected ? 1 : 0)
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: TabBarMetrics.hoverDuration)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.isDirty ? "Modified" : "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        ZStack(alignment: .top) {
            // Selected tab uses the terminal background so it visually
            // connects to the pane below. Other tabs stay transparent so the
            // (slightly lighter) tab-bar chrome shows through.
            if isSelected {
                backgroundColor
            } else {
                Color.clear
            }

            // Top accent indicator for selected tab. Desaturated when the
            // owning pane is inactive so the bar as a whole still reads as
            // unfocused, without greying the tab's terminal-colored fill.
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: TabBarMetrics.activeIndicatorHeight)
                    .saturation(isPaneActive ? 1 : 0)
            }

            // Right border separator
            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator)
                    .frame(width: 1)
            }
        }
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering)
            if tab.isDirty && !isHovered && !isCloseHovered {
                Circle()
                    .fill(TabBarColors.dirtyIndicator)
                    .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
            }

            // Close button (always shown for selected tab, on hover for others)
            if isSelected || isHovered || isCloseHovered {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(isCloseHovered ? TabBarColors.activeText : TabBarColors.inactiveText)
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .background(
                            Circle()
                                .fill(isCloseHovered ? TabBarColors.hoveredTabBackground : .clear)
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
            }
        }
        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }
}

// MARK: - Middle-Click Close

/// Transparent AppKit overlay that invokes `onMiddleClick` on middle-mouse-up.
///
/// The view only claims hit tests when the middle button (button 2) is the one
/// currently pressed, so left-clicks keep flowing to SwiftUI's `onTapGesture`
/// and right-clicks keep reaching any context menu. Close is dispatched on
/// `otherMouseUp` to match typical browser semantics (press + release on the
/// same tab), and only when the release happens inside the view's bounds.
private struct MiddleClickCloseView: NSViewRepresentable {
    let onMiddleClick: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        let view = MiddleClickNSView()
        view.onMiddleClick = onMiddleClick
        return view
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.onMiddleClick = onMiddleClick
    }

    final class MiddleClickNSView: NSView {
        var onMiddleClick: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // Only intercept events when the middle button is the one being
            // pressed. Bit 2 (value 4) is the middle/"other" button in
            // NSEvent.pressedMouseButtons' bitmask.
            let middlePressed = (NSEvent.pressedMouseButtons & (1 << 2)) != 0
            guard middlePressed, bounds.contains(point) else { return nil }
            return self
        }

        override func otherMouseDown(with event: NSEvent) {
            // Swallow so the event doesn't bubble; we'll act on mouseUp.
        }

        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else {
                super.otherMouseUp(with: event)
                return
            }
            let location = convert(event.locationInWindow, from: nil)
            if bounds.contains(location) {
                onMiddleClick?()
            }
        }
    }
}
