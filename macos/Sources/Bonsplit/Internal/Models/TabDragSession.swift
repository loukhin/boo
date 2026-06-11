import Foundation
import SwiftUI

/// Process-wide state for an in-flight Bonsplit tab drag.
///
/// Tab drags can cross window boundaries (each window owns its own
/// `BonsplitController`), so the drag state lives in a shared session
/// instead of on any single controller. Drop targets consult the session
/// both for visual feedback and to decide between an in-controller move
/// and a cross-controller transfer.
@MainActor
@Observable
final class TabDragSession {
    static let shared = TabDragSession()

    /// Tab currently being dragged, or nil when no drag is in flight.
    private(set) var tab: TabItem?

    /// Controller that owns the tab being dragged.
    ///
    /// Weak so a window closing mid-drag doesn't keep its controller alive;
    /// the session is short-lived and cleared on drop / mouse-up anyway.
    private(set) weak var sourceController: BonsplitController?

    /// Pane the drag started from.
    private(set) var sourcePaneId: PaneID?

    private init() {}

    func begin(tab: TabItem, source: BonsplitController, pane: PaneID) {
        self.tab = tab
        self.sourceController = source
        self.sourcePaneId = pane
    }

    func end() {
        tab = nil
        sourceController = nil
        sourcePaneId = nil
    }

    /// Whether the given pane in the given (internal) controller is the
    /// source of the current drag. Used for tab-bar saturation feedback.
    func isSource(pane: PaneID, in controller: SplitViewController) -> Bool {
        sourcePaneId == pane && sourceController?.internalController === controller
    }
}
