import Foundation

/// Where a cross-controller tab drop should land inside the receiving
/// controller. Passed to `BonsplitController.onTabTransferRequested` so the
/// host can complete the transfer with `adoptTab(_:inPane:atIndex:)` or
/// `splitPaneWithAdoptedTab(_:targetPaneId:orientation:insertFirst:)`.
public enum TabTransferDestination {
    /// Insert into an existing pane's tab strip. `index` of nil appends.
    case insert(pane: PaneID, index: Int?)

    /// Split an existing pane and place the tab in the newly created pane.
    case split(pane: PaneID, orientation: SplitOrientation, insertFirst: Bool)

    /// The pane the drop targets, regardless of destination kind.
    public var paneId: PaneID {
        switch self {
        case .insert(let pane, _): return pane
        case .split(let pane, _, _): return pane
        }
    }
}
