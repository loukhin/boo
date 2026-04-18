import SwiftUI

/// Main entry point for the Bonsplit library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = BonsplitController()
///
///     var body: some View {
///         BonsplitView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         }
///     }
/// }
/// ```
public struct BonsplitView<Content: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Tab, PaneID) -> Content
    private let onDividerDragEnd: (() -> Void)?

    /// Initialize with a controller and content builder
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - onDividerDragEnd: Called once after the user finishes dragging a
    ///     split divider. Hosts whose pane content loses first-responder
    ///     during the drag (e.g., embedded AppKit views with their own
    ///     tracking areas) can use this hook to restore focus.
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    public init(
        controller: BonsplitController,
        onDividerDragEnd: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Tab, PaneID) -> Content
    ) {
        self.controller = controller
        self.onDividerDragEnd = onDividerDragEnd
        self.contentBuilder = content
    }

    public var body: some View {
        // When rootNode is nil (no panes), render nothing. The host is
        // expected to handle this state (e.g., Boo closes the window).
        if controller.internalController.rootNode != nil {
            SplitViewContainer(
                contentBuilder: { tabItem, paneId in
                    contentBuilder(Tab(from: tabItem), PaneID(id: paneId.id))
                },
                showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
                contentViewLifecycle: controller.configuration.contentViewLifecycle,
                onGeometryChange: { [weak controller] isDragging in
                    controller?.notifyGeometryChange(isDragging: isDragging)
                },
                onDividerDragEnd: onDividerDragEnd
            )
            .environment(controller)
            .environment(controller.internalController)
        }
    }
}
