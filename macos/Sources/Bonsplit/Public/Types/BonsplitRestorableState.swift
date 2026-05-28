import CoreGraphics
import Foundation

/// Structural state needed to recreate a Bonsplit controller.
///
/// This intentionally stores the split tree in normalized model terms rather
/// than pixel geometry snapshots. Pixel snapshots are useful for external
/// observers, but restoration needs stable pane/tab identities, selected tabs,
/// and split divider ratios.
struct BonsplitRestorableState: Codable {
    let root: BonsplitRestorableNode?
    let focusedPaneId: PaneID?
    let zoomedPaneId: PaneID?

    init(
        root: BonsplitRestorableNode?,
        focusedPaneId: PaneID?,
        zoomedPaneId: PaneID? = nil
    ) {
        self.root = root
        self.focusedPaneId = focusedPaneId
        self.zoomedPaneId = zoomedPaneId
    }

    @MainActor
    init(controller: BonsplitController) {
        self.root = controller.internalController.rootNode.map(BonsplitRestorableNode.init(node:))
        self.focusedPaneId = controller.focusedPaneId
        self.zoomedPaneId = controller.zoomedPaneId
    }
}

indirect enum BonsplitRestorableNode: Codable {
    case pane(BonsplitRestorablePane)
    case split(BonsplitRestorableSplit)

    init(node: SplitNode) {
        switch node {
        case .pane(let pane):
            self = .pane(BonsplitRestorablePane(pane: pane))

        case .split(let split):
            self = .split(BonsplitRestorableSplit(split: split))
        }
    }

    var splitNode: SplitNode {
        switch self {
        case .pane(let pane):
            return .pane(pane.paneState)

        case .split(let split):
            return .split(split.splitState)
        }
    }
}

struct BonsplitRestorablePane: Codable {
    let id: PaneID
    let tabs: [BonsplitRestorableTab]
    let selectedTabId: TabID?

    init(id: PaneID, tabs: [BonsplitRestorableTab], selectedTabId: TabID?) {
        self.id = id
        self.tabs = tabs
        self.selectedTabId = selectedTabId
    }

    init(pane: PaneState) {
        self.id = pane.id
        self.tabs = pane.tabs.map(BonsplitRestorableTab.init(tab:))
        self.selectedTabId = pane.selectedTabId.map { TabID(id: $0) }
    }

    var paneState: PaneState {
        let tabItems = tabs.map(\.tabItem)
        let selectedId = selectedTabId.flatMap { selected -> UUID? in
            tabItems.contains { $0.id == selected.id } ? selected.id : nil
        }

        return PaneState(
            id: id,
            tabs: tabItems,
            selectedTabId: selectedId ?? tabItems.first?.id
        )
    }
}

struct BonsplitRestorableSplit: Codable {
    let id: UUID
    let orientation: SplitOrientation
    let dividerPosition: Double
    let first: BonsplitRestorableNode
    let second: BonsplitRestorableNode

    init(
        id: UUID,
        orientation: SplitOrientation,
        dividerPosition: Double,
        first: BonsplitRestorableNode,
        second: BonsplitRestorableNode
    ) {
        self.id = id
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }

    init(split: SplitState) {
        self.id = split.id
        self.orientation = split.orientation
        self.dividerPosition = Double(split.dividerPosition)
        self.first = BonsplitRestorableNode(node: split.first)
        self.second = BonsplitRestorableNode(node: split.second)
    }

    var splitState: SplitState {
        SplitState(
            id: id,
            orientation: orientation,
            first: first.splitNode,
            second: second.splitNode,
            dividerPosition: CGFloat(dividerPosition),
            animationOrigin: nil
        )
    }
}

struct BonsplitRestorableTab: Codable {
    let id: TabID
    let title: String
    let icon: String?
    let isDirty: Bool

    init(id: TabID, title: String, icon: String?, isDirty: Bool) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isDirty = isDirty
    }

    init(tab: TabItem) {
        self.id = TabID(id: tab.id)
        self.title = tab.title
        self.icon = tab.icon
        self.isDirty = tab.isDirty
    }

    var tabItem: TabItem {
        TabItem(id: id.id, title: title, icon: icon, isDirty: isDirty)
    }
}

extension BonsplitController {
    convenience init(
        configuration: BonsplitConfiguration = .default,
        restoring state: BonsplitRestorableState
    ) {
        self.init(configuration: configuration)
        restore(from: state)
    }

    func restorableState() -> BonsplitRestorableState {
        BonsplitRestorableState(controller: self)
    }

    func restore(from state: BonsplitRestorableState) {
        let tabDragEndedOutside = onTabDragEndedOutside
        internalController = SplitViewController(rootNode: state.root?.splitNode)
        onTabDragEndedOutside = tabDragEndedOutside

        if let focusedPaneId = state.focusedPaneId,
           internalController.rootNode?.findPane(focusedPaneId) != nil {
            internalController.focusedPaneId = focusedPaneId
        } else {
            internalController.focusedPaneId = internalController.rootNode?.allPaneIds.first
        }

        if let zoomedPaneId = state.zoomedPaneId,
           internalController.canToggleZoomedPane(zoomedPaneId) {
            internalController.zoomedPaneId = zoomedPaneId
        } else {
            internalController.zoomedPaneId = nil
        }
    }
}
