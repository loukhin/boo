import SwiftUI
import GhosttyKit

/// Titlebar accessory pill that flags debug / release-safe builds.
///
/// Visually mirrors `UpdatePill` (same font, capsule, padding) so that when
/// both pills appear side-by-side in the titlebar they read as part of the
/// same family. Click opens a popover with the full explanation; a system
/// tooltip on hover gives the short version.
struct BooDebugPill: View {
    @State private var showPopover = false

    /// Match `UpdatePill`'s 11pt medium so the two pills align optically.
    private let textFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// Short one-line version shown in the tooltip.
    private var tooltip: String {
        "You're running a debug build of Boo — performance will be degraded. Click for details."
    }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                // Icon carries the "warning" semantic. Orange (not yellow)
                // against a yellow fill is the standard macOS caution
                // treatment (see NSAlert, Xcode scheme warnings). Yellow
                // on yellow disappears; black reads too flat.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .frame(width: 14, height: 14)

                // Text uses primary foreground so it stays readable against
                // the soft yellow fill (yellow-on-yellow was the root cause
                // of the "looks invisible" feedback). `.primary` also adapts
                // to light/dark mode automatically.
                Text("Debug Build")
                    .font(Font(textFont))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.yellow.opacity(0.28))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel("Debug build warning")
        .accessibilityHint(tooltip)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            BooDebugPopoverView()
        }
    }
}

/// Popover content: the long-form explanation that used to live in the
/// banner at the top of the window.
private struct BooDebugPopoverView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Split icon + title so the icon stays orange (matches the
            // titlebar pill's caution treatment) while the title uses
            // `.primary` for readability. A plain `Label` would force
            // both to share one color.
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Debug Build")
                    .foregroundColor(.primary)
            }
            .font(.headline)

            Text(
                "Debug builds of Boo are very slow and you may experience " +
                "performance problems. Debug builds are only recommended " +
                "during development."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

/// Applies the same top/trailing padding ghostty uses for its right-aligned
/// titlebar accessories (see `TerminalWindow.UpdateAccessoryView`) so that
/// the pill hugs the traffic-light row the same way on every macOS version.
struct BooDebugAccessoryView: View {
    private var topPadding: CGFloat {
        if #available(macOS 26.0, *) { 5 } else { 4 }
    }

    var body: some View {
        BooDebugPill()
            .padding(.top, topPadding)
            .padding(.trailing, topPadding)
    }
}
