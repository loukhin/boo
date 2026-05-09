import AppKit
import SwiftUI
import GhosttyKit

// Bonsplit is vendored in macos/Sources/Bonsplit — same target, no import.

/// Top-level SwiftUI content of a Boo window.
///
/// Each Bonsplit tab hosts a ghostty surface via `Ghostty.SurfaceWrapper`,
/// which is the same wrapper used by upstream ghostty's `TerminalView`. Using
/// the upstream wrapper gives us correct sizing (its `GeometryReader`-driven
/// Metal surface plumbing is battle-tested) while Boo keeps pane focus in sync
/// from the underlying AppKit surface focus callback (`SurfaceView.focusDidChange`).
struct BooRootView: View {
    @ObservedObject var state: BooState

    var body: some View {
        // Debug build warning now lives in the titlebar as a pill
        // (see `BooDebugPill` / `BooController.configureWindow`). The old
        // inline banner used to sit above the Bonsplit view here.
        HStack(spacing: 0) {
            if state.isWorkspaceSidebarVisible {
                BooWorkspaceSidebar(state: state)
            }

            ZStack {
                ForEach(state.workspaces.filter { state.isWorkspaceMounted($0.id) }) { workspace in
                    workspaceView(workspace)
                        .opacity(workspace.id == state.activeWorkspaceId ? 1 : 0)
                        .allowsHitTesting(workspace.id == state.activeWorkspaceId)
                        .accessibilityHidden(workspace.id != state.activeWorkspaceId)
                        .zIndex(workspace.id == state.activeWorkspaceId ? 1 : 0)
                }
            }
        // No outer click-to-focus gesture here. Surface clicks are handled
        // by AppKit at the real terminal NSView level, and Boo syncs Bonsplit
        // focus from that source-of-truth callback. Bonsplit's own delegate
        // chain (`didSplitPane`, `didClosePane`, `didSelectTab`) handles the
        // explicit restore paths after structural changes.
        }
        // SurfaceWrapper needs the ghostty app as an @EnvironmentObject
        // for config access (split dimming, resize overlay, etc.).
        .environmentObject(state.ghostty)
        .environment(\.terminalBackgroundColor, state.terminalBackgroundColor)
        .environment(\.terminalChromeBackgroundColor, state.terminalChromeBackgroundColor)
        .environment(\.isWindowKey, state.isWindowKey)
        .frame(minWidth: 600, minHeight: 400)
    }

    private func workspaceView(_ workspace: BooWorkspace) -> some View {
        BonsplitView(
            controller: workspace.controller,
            // During a divider drag the SwiftUI gesture steals first-responder
            // from whichever ghostty surface currently had it (the surface's
            // tracking areas see the drag as a mouse event in a different
            // view). We can't keep focus *through* the drag without deeper
            // surface-level surgery, so we just push it back when the drag
            // ends — same net result from the user's perspective.
            onDividerDragEnd: { [weak state] in
                guard state?.activeWorkspaceId == workspace.id else { return }
                state?.focusCurrentTabSurface()
            },
            content: { tab, paneId in
                // Computed here so the body re-evaluates when Bonsplit's
                // PaneState (@Published selectedTabId) changes — that's our
                // hook for "user clicked a tab in the tab bar", since
                // Bonsplit's didSelectTab delegate does NOT fire for tab-bar
                // clicks (it only fires for programmatic selection).
                let isSelected = workspace.controller.selectedTab(inPane: paneId)?.id == tab.id

                if let surface = state.surfaces[tab.id] {
                    BooSurfaceContainer(
                        surface: surface,
                        isSelected: isSelected
                    )
                    // NOTE: we intentionally do NOT use `.id(surface)` here.
                    // With `keepAllAlive` mode, tabs live in ForEach inside
                    // different pane ZStacks. When a tab moves between panes,
                    // SwiftUI's view identity reconciliation with `.id()` gets
                    // confused and can leave views unmounted. Without `.id()`,
                    // SwiftUI recreates the wrapper on reparent, but the
                    // underlying SurfaceView NSView reattaches correctly since
                    // it's passed by reference.
                } else {
                    BooTabPlaceholder(title: tab.title)
                }
            }
        )
    }
}

/// Wraps a single ghostty surface for one tab. Uses upstream
/// `Ghostty.SurfaceWrapper` so we inherit its correct Metal-surface sizing
/// and SwiftUI focus machinery.
private struct BooSurfaceContainer: View {
    let surface: Ghostty.SurfaceView
    let isSelected: Bool

    var body: some View {
        // NOTE: We intentionally do NOT auto-focus when isSelected changes.
        // During tab drag operations, the source pane auto-selects a
        // remaining tab which would steal focus from the target pane.
        // Focus is managed explicitly via focusSurface() calls.
        //
        // Important: no SwiftUI TapGesture here. In nested split layouts
        // the wrapper gesture proved unreliable: the terminal under the
        // mouse could gain AppKit focus while a sibling wrapper received
        // the SwiftUI tap event. Boo now syncs Bonsplit pane focus from
        // `SurfaceView.focusDidChange(_:)`, i.e. from the actual NSView
        // that became first responder.
        Ghostty.SurfaceWrapper(
            surfaceView: surface,
            isSplit: true,
            showsGrabHandle: false
        )
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

