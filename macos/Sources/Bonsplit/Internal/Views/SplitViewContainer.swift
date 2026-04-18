import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (TabItem, PaneID) -> Content
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var onDividerDragEnd: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // NOTE: previously this view was `.focusable()` (with a
                // `.focusEffectDisabled()` to hide the ring). That
                // collaborates with a focus-owning child (in Boo, ghostty's
                // `SurfaceRepresentable` uses `.focused($surfaceFocus)`)
                // to produce a focus tug-of-war: clicking a surface nested
                // inside splits causes SwiftUI to re-resolve focus up to
                // this container, which can bounce the @FocusedValue
                // between adjacent panes and oscillate the visible cursor.
                //
                // Bonsplit's own navigation uses controller state
                // (`focusedPaneId`), not SwiftUI focus, so removing this
                // modifier doesn't break anything; hosts that *do* want
                // keyboard-focusable pane navigation can add it back at
                // the pane level.
                .onChange(of: geometry.size) { _, newSize in
                    updateContainerFrame(geometry: geometry)
                }
                .onAppear {
                    updateContainerFrame(geometry: geometry)
                }
        }
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        // Get frame in global coordinate space
        let frame = geometry.frame(in: .global)
        controller.containerFrame = frame
        onGeometryChange?(false)  // Container resize is not a drag
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        if let rootNode = controller.rootNode {
            SplitNodeView(
                node: rootNode,
                contentBuilder: contentBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                onDividerDragEnd: onDividerDragEnd
            )
        }
    }
}
