import SwiftUI

/// Recursively renders a node in the split tree (pane or nested split).
///
/// Since `SplitContainerView` is now pure SwiftUI, there is no need to wrap
/// panes in an `NSHostingController`/`NSViewRepresentable` to satisfy AppKit
/// layout constraints — SwiftUI handles sizing natively. This used to hold a
/// `SinglePaneWrapper` for that reason; it's been removed.
struct SplitNodeView<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let node: SplitNode
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var onDividerDragEnd: (() -> Void)?

    var body: some View {
        switch node {
        case .pane(let paneState):
            PaneContainerView(
                pane: paneState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )

        case .split(let splitState):
            SplitContainerView(
                splitState: splitState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                onDividerDragEnd: onDividerDragEnd
            )
        }
    }
}
