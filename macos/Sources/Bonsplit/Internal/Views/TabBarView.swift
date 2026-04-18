import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Tab bar view with scrollable tabs, drag/drop support, and split buttons
struct TabBarView: View {
    @Environment(BonsplitController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController

    @Bindable var pane: PaneState
    var showSplitButtons: Bool = true

    @State private var dropTargetIndex: Int?
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
    }

    /// Whether this pane is the currently focused pane.
    ///
    /// Compute this directly from the internal controller environment instead
    /// of receiving it relayed through parent view props. The tab bar's visual
    /// focused state (saturation/background) is ultimately driven by
    /// `SplitViewController.focusedPaneId`; reading that source of truth here
    /// gives SwiftUI the most direct observation path and avoids stale visual
    /// state when an ancestor doesn't invalidate exactly when focus changes.
    private var isFocused: Bool {
        splitViewController.focusedPaneId == pane.id
    }

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    /// Width reserved for the trailing split-button lane.
    ///
    /// This is intentionally a bit wider than the buttons themselves so there
    /// is still some draggable empty chrome on the right.
    private let splitButtonLaneWidth: CGFloat = 54
    private let splitButtonTrailingInset: CGFloat = 6

    /// The portion of the trailing lane that should actually occlude tab
    /// content because the buttons visually occupy it. Keep this narrower than
    /// `splitButtonLaneWidth` so the lane still feels like titlebar chrome
    /// instead of a huge dead gap.
    private let splitButtonMaskClearWidth: CGFloat = 48
    private let splitButtonMaskFadeWidth: CGFloat = 12


    var body: some View {
        GeometryReader { containerGeo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TabBarMetrics.tabSpacing) {
                        ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                            tabItem(for: tab, at: index)
                                .id(tab.id)
                        }

                        // No separate end-of-strip spacer here; trailing drop
                        // behavior is provided by the right-side overlay band.
                    }
                    .padding(.horizontal, TabBarMetrics.barPadding)
                    .background(
                        GeometryReader { contentGeo in
                            Color.clear
                                .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                                    scrollOffset = -newFrame.minX
                                    contentWidth = newFrame.width
                                }
                                .onAppear {
                                    let frame = contentGeo.frame(in: .named("tabScroll"))
                                    scrollOffset = -frame.minX
                                    contentWidth = frame.width
                                }
                        }
                    )
                }
                .overlay(alignment: .trailing) {
                    HStack(spacing: 0) {
                        let fixedTrailingLane = showSplitButtons ? splitButtonLaneWidth : 0
                        let trailing = max(0, containerGeo.size.width - contentWidth - fixedTrailingLane)
                        if trailing >= 1 {
                            WindowDragZoneView()
                                .frame(width: trailing, height: TabBarMetrics.tabHeight)
                                .onDrop(of: [.text], delegate: TabDropDelegate(
                                    targetIndex: pane.tabs.count,
                                    pane: pane,
                                    bonsplitController: controller,
                                    controller: splitViewController,
                                    dropTargetIndex: $dropTargetIndex
                                ))
                        }

                        if showSplitButtons {
                            trailingButtonLaneDropZone
                        }
                    }
                    .overlay(alignment: .leading) {
                        if dropTargetIndex == pane.tabs.count {
                            dropIndicator
                        }
                    }
                }
                .coordinateSpace(name: "tabScroll")
                .onAppear {
                    containerWidth = containerGeo.size.width
                    if let tabId = pane.selectedTabId {
                        proxy.scrollTo(tabId, anchor: .center)
                    }
                }
                .onChange(of: containerGeo.size.width) { _, newWidth in
                    containerWidth = newWidth
                }
                .onChange(of: pane.selectedTabId) { _, newTabId in
                    if let tabId = newTabId {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(tabId, anchor: .center)
                        }
                    }
                }
                .frame(height: TabBarMetrics.barHeight)
                .mask(tabStripMask)
                .overlay(alignment: .trailing) {
                    if showSplitButtons {
                        splitButtons
                    }
                }
            }
        }
        .frame(height: TabBarMetrics.barHeight)
        .contentShape(Rectangle())
        .background(tabBarBackground)
        .saturation(shouldShowFullSaturation ? 1.0 : 0)
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: TabItem, at index: Int) -> some View {
        TabItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            onSelect: {
                withAnimation(.easeInOut(duration: TabBarMetrics.selectionDuration)) {
                    pane.selectTab(tab.id)
                    controller.focusPane(pane.id)
                }
            },
            onClose: {
                withAnimation(.easeInOut(duration: TabBarMetrics.closeDuration)) {
                    _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                }
            }
        )
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            TabDragPreview(tab: tab)
        }
        .onDrop(of: [.text], delegate: TabDropDelegate(
            targetIndex: index,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                dropIndicator
            }
        }
    }

    // MARK: - Item Provider

    private func createItemProvider(for tab: TabItem) -> NSItemProvider {
        // Set drag source for visual feedback
        splitViewController.draggingTab = tab
        splitViewController.dragSourcePaneId = pane.id

        let transfer = TabTransferData(tab: tab, sourcePaneId: pane.id.id)
        if let data = try? JSONEncoder().encode(transfer),
           let string = String(data: data, encoding: .utf8) {
            return NSItemProvider(object: string as NSString)
        }
        return NSItemProvider()
    }

    // MARK: - Fixed Trailing Drop / Drag Band

    @ViewBuilder
    private var trailingButtonLaneDropZone: some View {
        // Fixed right-edge band aligned with the floating split-button lane.
        // Unlike the old scroll-content spacer, this does not drift as the tab
        // strip scrolls, so its interactive area stays where the buttons and
        // mask actually live.
        WindowDragZoneView()
            .frame(width: splitButtonLaneWidth, height: TabBarMetrics.tabHeight)
            .onDrop(of: [.text], delegate: TabDropDelegate(
                targetIndex: pane.tabs.count,
                pane: pane,
                bonsplitController: controller,
                controller: splitViewController,
                dropTargetIndex: $dropTargetIndex
            ))
    }

    // MARK: - Drop Indicator

    @ViewBuilder
    private var dropIndicator: some View {
        Capsule()
            .fill(TabBarColors.dropIndicator)
            .frame(width: TabBarMetrics.dropIndicatorWidth, height: TabBarMetrics.dropIndicatorHeight)
            .offset(x: -1)
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtons: some View {
        HStack(spacing: 4) {
            Button {
                controller.splitPane(pane.id, orientation: .horizontal)
            } label: {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Right")

            Button {
                controller.splitPane(pane.id, orientation: .vertical)
            } label: {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("Split Down")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, splitButtonTrailingInset)
        .frame(width: splitButtonLaneWidth, alignment: .trailing)
    }

    // MARK: - Tab Strip Mask

    /// Mask the scrollable tab strip so content fades at the edges and is
    /// fully hidden under the trailing split-button lane. This prevents tabs
    /// from visually sliding behind the floating buttons when the strip is
    /// crowded or scrolled all the way right.
    @ViewBuilder
    private var tabStripMask: some View {
        let fadeWidth: CGFloat = 24
        let buttonFadeWidth: CGFloat = showSplitButtons ? splitButtonMaskFadeWidth : 0
        let buttonClearWidth: CGFloat = showSplitButtons ? splitButtonMaskClearWidth : 0

        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollLeft ? fadeWidth : 0)

            Rectangle().fill(Color.black)

            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: canScrollRight || showSplitButtons ? buttonFadeWidth : 0)

            if showSplitButtons {
                Color.clear.frame(width: buttonClearWidth)
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var tabBarBackground: some View {
        Rectangle()
            .fill(isFocused ? TabBarColors.barBackground : TabBarColors.barBackground.opacity(0.95))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(TabBarColors.separator)
                    .frame(height: 1)
            }
    }
}

// MARK: - Window Drag Helpers

@discardableResult
private func performStandardWindowDragOrDoubleClick(window: NSWindow?, event: NSEvent) -> Bool {
    guard let window else { return false }

    if event.clickCount >= 2 {
        let action = UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
        switch action {
        case "Minimize":
            window.miniaturize(nil)
        default:
            window.zoom(nil)
        }
        return true
    }

    let wasMovable = window.isMovable
    window.isMovable = true
    window.performDrag(with: event)
    window.isMovable = wasMovable
    return true
}

/// Real AppKit drag zone used only in visually empty tab-bar regions.
///
/// We deliberately attach this view only where the strip is actually empty
/// (after the last tab, trailing viewport slack, and under the split-button
/// overlay) instead of covering the whole tab bar. That keeps the behavior
/// easy to reason about: interactive controls own their clicks, and only true
/// chrome starts a window drag.
private struct WindowDragZoneView: NSViewRepresentable {
    func makeNSView(context: Context) -> DragZoneNSView {
        DragZoneNSView()
    }

    func updateNSView(_ nsView: DragZoneNSView, context: Context) {}

    final class DragZoneNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? {
            bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            if !performStandardWindowDragOrDoubleClick(window: window, event: event) {
                super.mouseDown(with: event)
            }
        }
    }
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let bonsplitController: BonsplitController
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?

    func performDrop(info: DropInfo) -> Bool {
        dropTargetIndex = nil

        guard let provider = info.itemProviders(for: [.text]).first else {
            // Clear drag state
            controller.draggingTab = nil
            controller.dragSourcePaneId = nil
            return false
        }

        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                // Clear drag state
                controller.draggingTab = nil
                controller.dragSourcePaneId = nil

                // Handle both Data and String representations
                let string: String?
                if let data = item as? Data {
                    string = String(data: data, encoding: .utf8)
                } else if let nsString = item as? NSString {
                    string = nsString as String
                } else if let str = item as? String {
                    string = str
                } else {
                    string = nil
                }

                guard let string, let transfer = decodeTransfer(from: string) else {
                    return
                }

                // Same pane - reorder
                if transfer.sourcePaneId == pane.id.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == transfer.tab.id }) else {
                        return
                    }
                    withAnimation(.spring(duration: TabBarMetrics.reorderDuration, bounce: TabBarMetrics.reorderBounce)) {
                        pane.moveTab(from: sourceIndex, to: targetIndex)
                    }
                } else {
                    // Different pane - transfer
                    guard let sourcePaneId = controller.rootNode?.allPaneIds.first(where: { $0.id == transfer.sourcePaneId }) else {
                        return
                    }
                    withAnimation(.spring(duration: TabBarMetrics.reorderDuration, bounce: TabBarMetrics.reorderBounce)) {
                        bonsplitController.moveTab(
                            Tab(from: transfer.tab),
                            from: sourcePaneId,
                            to: pane.id,
                            atIndex: targetIndex
                        )
                    }
                }
            }
        }

        return true
    }

    func dropEntered(info: DropInfo) {
        dropTargetIndex = targetIndex
    }

    func dropExited(info: DropInfo) {
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }
}
