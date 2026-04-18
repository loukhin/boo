import SwiftUI
import Bonsplit

/// Top-level SwiftUI content of a Boo window. A `BonsplitView` whose tab
/// contents are ghostty surfaces.
struct BooRootView: View {
    @ObservedObject var state: BooState

    var body: some View {
        BonsplitView(controller: state.controller) { tab, paneId in
            // Bonsplit's tab bar does not invoke the `didSelectTab` delegate
            // when the user clicks a tab in the UI (it calls pane.selectTab
            // directly, bypassing the controller). So we compute selection
            // here and hand it to the surface container, which uses
            // `.onChange` to grab AppKit focus when it becomes selected.
            let isSelected = state.controller.selectedTab(inPane: paneId)?.id == tab.id

            if let surface = state.surfaces[tab.id] {
                BooSurfaceContainer(
                    surface: surface,
                    isSelected: isSelected
                )
            } else {
                BooTabPlaceholder(title: tab.title)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

/// Wraps a `Ghostty.SurfaceView` in the SurfaceRepresentable so SwiftUI can
/// host it. The `isSelected` binding tracks whether this tab is currently
/// selected in its pane; when it flips to true we push AppKit
/// first-responder focus into the surface.
private struct BooSurfaceContainer: View {
    let surface: Ghostty.SurfaceView
    let isSelected: Bool

    var body: some View {
        GeometryReader { geo in
            Ghostty.SurfaceRepresentable(view: surface, size: geo.size)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: isSelected) { _, nowSelected in
            if nowSelected {
                Ghostty.moveFocus(to: surface)
            }
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
