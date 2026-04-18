import SwiftUI
import GhosttyKit

// Bonsplit is vendored in macos/Sources/Bonsplit — same target, no import.

/// Top-level SwiftUI content of a Boo window.
///
/// Each Bonsplit tab hosts a ghostty surface via `Ghostty.SurfaceWrapper`,
/// which is the same wrapper used by upstream ghostty's `TerminalView`. Using
/// the upstream wrapper gives us correct sizing (its `GeometryReader`-driven
/// Metal surface plumbing is battle-tested) and hands us SwiftUI focus
/// tracking via `focusedValue(\.ghosttySurfaceView, …)` for free.
///
/// A thin observer layer reads that focused-value at the root and syncs it
/// into Bonsplit's pane focus, which Bonsplit doesn't otherwise learn about
/// when the user clicks inside a surface (Bonsplit only updates focus when
/// its own tab-bar UI is clicked).
struct BooRootView: View {
    @ObservedObject var state: BooState

    var body: some View {
        BonsplitView(
            controller: state.controller,
            // During a divider drag the SwiftUI gesture steals first-responder
            // from whichever ghostty surface currently had it (the surface's
            // tracking areas see the drag as a mouse event in a different
            // view). We can't keep focus *through* the drag without deeper
            // surface-level surgery, so we just push it back when the drag
            // ends — same net result from the user's perspective.
            onDividerDragEnd: { [weak state] in state?.focusCurrentTabSurface() }
        ) { tab, paneId in
            // Computed here so the body re-evaluates when Bonsplit's
            // PaneState (@Published selectedTabId) changes — that's our
            // hook for "user clicked a tab in the tab bar", since
            // Bonsplit's didSelectTab delegate does NOT fire for tab-bar
            // clicks (it only fires for programmatic selection).
            let isSelected = state.controller.selectedTab(inPane: paneId)?.id == tab.id

            if let surface = state.surfaces[tab.id] {
                BooSurfaceContainer(
                    surface: surface,
                    isSelected: isSelected,
                    paneId: paneId,
                    state: state
                )
                // Identity keyed on the surface itself so SwiftUI preserves
                // the representable across tab/pane reparenting. Bonsplit's
                // split-tree is now pure SwiftUI, so reshaping doesn't tear
                // down the NSView subtree and we no longer need to force a
                // remount on pane close.
                .id(ObjectIdentifier(surface).hashValue)
            } else {
                BooTabPlaceholder(title: tab.title)
            }
        }
        // SurfaceWrapper needs the ghostty app as an @EnvironmentObject
        // for config access (split dimming, resize overlay, etc.).
        .environmentObject(state.ghostty)
        .frame(minWidth: 600, minHeight: 400)
    }
}

/// Wraps a single ghostty surface for one tab. Uses upstream
/// `Ghostty.SurfaceWrapper` so we inherit its correct Metal-surface sizing
/// and SwiftUI focus machinery.
private struct BooSurfaceContainer: View {
    let surface: Ghostty.SurfaceView
    let isSelected: Bool
    let paneId: PaneID
    let state: BooState

    /// Surface that SwiftUI currently reports as focused. `SurfaceWrapper`
    /// publishes this via `.focusedValue(\.ghosttySurfaceView, surfaceView)`;
    /// reading it here lets us tell Bonsplit which pane is now active when
    /// the user clicks into a surface.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface

    var body: some View {
        Ghostty.SurfaceWrapper(surfaceView: surface, isSplit: true)
            // Push AppKit first-responder into our surface when the user
            // clicks a different Bonsplit tab. Without this, tab-bar clicks
            // change selection but the old tab's surface keeps keyboard
            // focus (see note above about didSelectTab not firing).
            .onChange(of: isSelected) { _, nowSelected in
                if nowSelected {
                    Ghostty.moveFocus(to: surface)
                }
            }
            // When SwiftUI focus lands on this tab's surface (via click or
            // tab switch), update Bonsplit's focused pane so subsequent
            // splits / closes target the correct pane.
            .onChange(of: focusedSurface) { _, newFocus in
                guard let newFocus, newFocus === surface else { return }
                state.controller.focusPane(paneId)
            }
    }
}

/// Fallback shown only if a tab has no surface yet (shouldn't happen in
/// normal flow, but useful while ghostty is still initializing).
private struct BooTabPlaceholder: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.monospaced())
            Text("waiting for ghostty runtime\u{2026}")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
