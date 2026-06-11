import Foundation
import SwiftUI

/// Central controller managing the entire split view state (internal implementation)
@Observable
@MainActor
final class SplitViewController {
    /// The root node of the split tree. `nil` when no panes exist (e.g.,
    /// before the first tab is created or after the last pane is closed).
    var rootNode: SplitNode?

    /// Currently focused pane ID
    var focusedPaneId: PaneID?

    /// Pane currently zoomed to occupy the full split area.
    var zoomedPaneId: PaneID?

    /// Callback when a tab drag ends outside any valid target
    ///
    /// NOTE: In-flight drag state itself lives in `TabDragSession.shared`
    /// because drags can cross window (and therefore controller) boundaries.
    var onTabDragEndedOutside: ((TabItem, PaneID, NSPoint?) -> Void)?

    /// Current frame of the entire split view container
    var containerFrame: CGRect = .zero

    /// Flag to prevent notification loops during external updates
    var isExternalUpdateInProgress: Bool = false

    /// Timestamp of last geometry notification for debouncing
    var lastGeometryNotificationTime: TimeInterval = 0

    /// Callback for geometry changes
    var onGeometryChange: (() -> Void)?

    init(rootNode: SplitNode? = nil) {
        self.rootNode = rootNode
        self.focusedPaneId = rootNode?.allPaneIds.first
    }

    var isSplit: Bool {
        guard let rootNode,
              case .split = rootNode else { return false }
        return true
    }

    var visibleRootNode: SplitNode? {
        if let zoomedPaneId,
           let pane = rootNode?.findPane(zoomedPaneId) {
            return .pane(pane)
        }

        return rootNode
    }

    func canToggleZoomedPane(_ paneId: PaneID? = nil) -> Bool {
        guard isSplit,
              let paneId = paneId ?? focusedPaneId else { return false }
        return rootNode?.findPane(paneId) != nil
    }

    @discardableResult
    func toggleZoomedPane(_ paneId: PaneID? = nil) -> Bool {
        guard let paneId = paneId ?? focusedPaneId,
              canToggleZoomedPane(paneId) else { return false }

        if zoomedPaneId == paneId {
            zoomedPaneId = nil
        } else {
            zoomedPaneId = paneId
            focusedPaneId = paneId
        }

        return true
    }

    func canEqualizeSplits() -> Bool {
        isSplit
    }

    @discardableResult
    func equalizeSplits() -> Bool {
        guard let rootNode,
              canEqualizeSplits() else { return false }

        _ = equalizeNode(rootNode)
        return true
    }

    func canResizeSplit(
        containing paneId: PaneID,
        direction: NavigationDirection
    ) -> Bool {
        guard let rootNode else { return false }
        return resizeTarget(
            in: rootNode,
            containing: paneId,
            direction: direction,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            current: nil
        ) != nil
    }

    @discardableResult
    func resizeSplit(
        containing paneId: PaneID,
        direction: NavigationDirection,
        amount: UInt16
    ) -> Bool {
        guard let rootNode else { return false }
        guard let target = resizeTarget(
            in: rootNode,
            containing: paneId,
            direction: direction,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            current: nil
        ) else { return false }

        let containerSize = containerFrame.size
        let targetLength: CGFloat
        switch target.split.orientation {
        case .horizontal:
            targetLength = max(1, target.bounds.width * max(1, containerSize.width))
        case .vertical:
            targetLength = max(1, target.bounds.height * max(1, containerSize.height))
        }

        let delta = CGFloat(amount) / targetLength
        let oldPosition = target.split.dividerPosition
        let newPosition: CGFloat
        switch (target.split.orientation, direction) {
        case (.horizontal, .left), (.vertical, .up):
            newPosition = oldPosition - delta
        case (.horizontal, .right), (.vertical, .down):
            newPosition = oldPosition + delta
        default:
            return false
        }

        target.split.dividerPosition = Self.clampDividerPosition(newPosition)
        zoomedPaneId = nil
        return target.split.dividerPosition != oldPosition
    }

    // MARK: - Focus Management

    /// Set focus to a specific pane
    func focusPane(_ paneId: PaneID) {
        guard rootNode?.findPane(paneId) != nil else { return }
        focusedPaneId = paneId
    }

    /// Get the currently focused pane state
    var focusedPane: PaneState? {
        guard let focusedPaneId, let rootNode else { return nil }
        return rootNode.findPane(focusedPaneId)
    }

    // MARK: - Split Operations

    /// Split the specified pane in the given orientation
    func splitPane(_ paneId: PaneID, orientation: SplitOrientation, with newTab: TabItem? = nil, insertFirst: Bool = false) {
        guard let currentRoot = rootNode else { return }
        rootNode = splitNodeRecursively(
            node: currentRoot,
            targetPaneId: paneId,
            orientation: orientation,
            newTab: newTab,
            insertFirst: insertFirst
        )
    }

    private func splitNodeRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        newTab: TabItem?,
        insertFirst: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                // Create new pane - empty if no tab provided (gives developer full control)
                let newPane: PaneState
                if let tab = newTab {
                    newPane = PaneState(tabs: [tab])
                } else {
                    newPane = PaneState(tabs: [])
                }

                // Start with divider at the edge so there's no flash before animation
                let splitState: SplitState
                if insertFirst {
                    // New pane goes first (left or top) - starts at 0, animates to 0.5
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(newPane),
                        second: .pane(paneState),
                        dividerPosition: 0.0,
                        animationOrigin: .fromFirst
                    )
                } else {
                    // New pane goes second (right or bottom) - starts at 1, animates to 0.5
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(paneState),
                        second: .pane(newPane),
                        dividerPosition: 1.0,
                        animationOrigin: .fromSecond
                    )
                }

                // Focus the new pane
                focusedPaneId = newPane.id

                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTab: newTab,
                insertFirst: insertFirst
            )
            splitState.second = splitNodeRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTab: newTab,
                insertFirst: insertFirst
            )
            return .split(splitState)
        }
    }

    /// Split a pane with a specific tab, optionally inserting the new pane first
    func splitPaneWithTab(_ paneId: PaneID, orientation: SplitOrientation, tab: TabItem, insertFirst: Bool) {
        guard let currentRoot = rootNode else { return }
        rootNode = splitNodeWithTabRecursively(
            node: currentRoot,
            targetPaneId: paneId,
            orientation: orientation,
            tab: tab,
            insertFirst: insertFirst
        )
    }

    private func splitNodeWithTabRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        tab: TabItem,
        insertFirst: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                // Create new pane with the tab
                let newPane = PaneState(tabs: [tab])

                // Start with divider at the edge so there's no flash before animation
                let splitState: SplitState
                if insertFirst {
                    // New pane goes first (left or top) - starts at 0, animates to 0.5
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(newPane),
                        second: .pane(paneState),
                        dividerPosition: 0.0,
                        animationOrigin: .fromFirst
                    )
                } else {
                    // New pane goes second (right or bottom) - starts at 1, animates to 0.5
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(paneState),
                        second: .pane(newPane),
                        dividerPosition: 1.0,
                        animationOrigin: .fromSecond
                    )
                }

                // Focus the new pane
                focusedPaneId = newPane.id

                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeWithTabRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
            splitState.second = splitNodeWithTabRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
            return .split(splitState)
        }
    }

    /// Close a pane and collapse the split. If this is the last pane,
    /// `rootNode` becomes `nil` and `focusedPaneId` is cleared.
    func closePane(_ paneId: PaneID) {
        guard let currentRoot = rootNode else { return }

        let (newRoot, siblingPaneId) = closePaneRecursively(node: currentRoot, targetPaneId: paneId)

        rootNode = newRoot
        clearInvalidZoomedPane()

        // Only change focusedPaneId if we're closing the currently focused pane.
        // Otherwise, keep the existing focus (e.g., after a tab move, the target
        // pane should stay focused even when the empty source pane closes).
        if focusedPaneId == paneId {
            focusedPaneId = siblingPaneId ?? newRoot?.allPaneIds.first
        } else if let currentFocus = focusedPaneId,
                  newRoot?.findPane(currentFocus) == nil {
            // The focused pane no longer exists (shouldn't happen normally)
            focusedPaneId = siblingPaneId ?? newRoot?.allPaneIds.first
        }
    }

    private func closePaneRecursively(
        node: SplitNode,
        targetPaneId: PaneID
    ) -> (SplitNode?, PaneID?) {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                return (nil, nil)
            }
            return (node, nil)

        case .split(let splitState):
            // Check if either direct child is the target
            if case .pane(let firstPane) = splitState.first, firstPane.id == targetPaneId {
                let focusTarget = splitState.second.allPaneIds.first
                return (splitState.second, focusTarget)
            }

            if case .pane(let secondPane) = splitState.second, secondPane.id == targetPaneId {
                let focusTarget = splitState.first.allPaneIds.first
                return (splitState.first, focusTarget)
            }

            // Recursively check children
            let (newFirst, focusFromFirst) = closePaneRecursively(node: splitState.first, targetPaneId: targetPaneId)
            if newFirst == nil {
                return (splitState.second, splitState.second.allPaneIds.first)
            }

            let (newSecond, focusFromSecond) = closePaneRecursively(node: splitState.second, targetPaneId: targetPaneId)
            if newSecond == nil {
                return (splitState.first, splitState.first.allPaneIds.first)
            }

            if let newFirst { splitState.first = newFirst }
            if let newSecond { splitState.second = newSecond }

            return (.split(splitState), focusFromFirst ?? focusFromSecond)
        }
    }

    // MARK: - Tab Operations

    /// Add a tab to the focused pane (or specified pane). If `rootNode` is
    /// `nil`, a new pane is created to hold the tab.
    func addTab(_ tab: TabItem, toPane paneId: PaneID? = nil, atIndex index: Int? = nil) {
        // Bootstrap: create initial pane if tree is empty
        if rootNode == nil {
            let newPane = PaneState(tabs: [tab])
            rootNode = .pane(newPane)
            focusedPaneId = newPane.id
            return
        }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId,
              let pane = rootNode?.findPane(targetPaneId) else { return }

        if let index {
            pane.insertTab(tab, at: index)
        } else {
            pane.addTab(tab)
        }
    }

    /// Move a tab from one pane to another
    func moveTab(_ tab: TabItem, from sourcePaneId: PaneID, to targetPaneId: PaneID, atIndex index: Int? = nil) {
        guard let rootNode,
              let sourcePane = rootNode.findPane(sourcePaneId),
              let targetPane = rootNode.findPane(targetPaneId) else { return }

        // Remove from source
        sourcePane.removeTab(tab.id)

        // Add to target
        if let index {
            targetPane.insertTab(tab, at: index)
        } else {
            targetPane.addTab(tab)
        }

        // Focus target pane
        focusPane(targetPaneId)

        // If source pane is now empty, close it. We defer this with a
        // longer delay to give SwiftUI time to fully settle the view
        // hierarchy after the tab move. Without sufficient delay, the
        // structural change (split → single pane) can confuse SwiftUI's
        // view identity reconciliation and cause views to unmount.
        if sourcePane.tabs.isEmpty {
            let paneToClose = sourcePaneId
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.closePane(paneToClose)
            }
        }
    }

    /// Close a tab in a specific pane. If the pane becomes empty, it is
    /// destroyed (which may leave `rootNode` nil if it was the last pane).
    func closeTab(_ tabId: UUID, inPane paneId: PaneID) {
        guard let pane = rootNode?.findPane(paneId) else { return }

        pane.removeTab(tabId)

        // Destroy empty panes unconditionally
        if pane.tabs.isEmpty {
            closePane(paneId)
        }
    }

    // MARK: - Keyboard Navigation

    /// Navigate focus to an adjacent pane based on spatial position
    func navigateFocus(direction: NavigationDirection) {
        guard let currentPaneId = focusedPaneId,
              let rootNode else { return }

        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == currentPaneId })?.bounds else { return }

        if let targetPaneId = findBestNeighbor(from: currentBounds, currentPaneId: currentPaneId,
                                               direction: direction, allPaneBounds: allPaneBounds) {
            focusPane(targetPaneId)
        }
        // No neighbor found = at edge, do nothing
    }

    private func findBestNeighbor(from currentBounds: CGRect, currentPaneId: PaneID,
                                  direction: NavigationDirection, allPaneBounds: [PaneBounds]) -> PaneID? {
        let epsilon: CGFloat = 0.001

        // Filter to panes in the target direction
        let candidates = allPaneBounds.filter { paneBounds in
            guard paneBounds.paneId != currentPaneId else { return false }
            let b = paneBounds.bounds
            switch direction {
            case .left:  return b.maxX <= currentBounds.minX + epsilon
            case .right: return b.minX >= currentBounds.maxX - epsilon
            case .up:    return b.maxY <= currentBounds.minY + epsilon
            case .down:  return b.minY >= currentBounds.maxY - epsilon
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Score by overlap (perpendicular axis) and distance
        let scored: [(PaneID, CGFloat, CGFloat)] = candidates.map { c in
            let overlap: CGFloat
            let distance: CGFloat

            switch direction {
            case .left, .right:
                // Vertical overlap for horizontal movement
                overlap = max(0, min(currentBounds.maxY, c.bounds.maxY) - max(currentBounds.minY, c.bounds.minY))
                distance = direction == .left ? (currentBounds.minX - c.bounds.maxX) : (c.bounds.minX - currentBounds.maxX)
            case .up, .down:
                // Horizontal overlap for vertical movement
                overlap = max(0, min(currentBounds.maxX, c.bounds.maxX) - max(currentBounds.minX, c.bounds.minX))
                distance = direction == .up ? (currentBounds.minY - c.bounds.maxY) : (c.bounds.minY - currentBounds.maxY)
            }

            return (c.paneId, overlap, distance)
        }

        // Sort: prefer more overlap, then closer distance
        let sorted = scored.sorted { a, b in
            if abs(a.1 - b.1) > epsilon { return a.1 > b.1 }
            return a.2 < b.2
        }

        return sorted.first?.0
    }

    /// Create a new tab in the focused pane
    func createNewTab() {
        guard let pane = focusedPane else { return }
        let count = pane.tabs.count + 1
        let newTab = TabItem(title: "Untitled \(count)", icon: "doc")
        pane.addTab(newTab)
    }

    /// Close the currently selected tab in the focused pane
    func closeSelectedTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId else { return }
        closeTab(selectedTabId, inPane: pane.id)
    }

    /// Select the previous tab in the focused pane
    func selectPreviousTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }

        let newIndex = currentIndex > 0 ? currentIndex - 1 : pane.tabs.count - 1
        pane.selectTab(pane.tabs[newIndex].id)
    }

    /// Select the next tab in the focused pane
    func selectNextTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }

        let newIndex = currentIndex < pane.tabs.count - 1 ? currentIndex + 1 : 0
        pane.selectTab(pane.tabs[newIndex].id)
    }

    // MARK: - Split State Access

    /// Find a split state by its UUID
    func findSplit(_ splitId: UUID) -> SplitState? {
        guard let rootNode else { return nil }
        return findSplitRecursively(in: rootNode, id: splitId)
    }

    private func findSplitRecursively(in node: SplitNode, id: UUID) -> SplitState? {
        switch node {
        case .pane:
            return nil
        case .split(let splitState):
            if splitState.id == id {
                return splitState
            }
            if let found = findSplitRecursively(in: splitState.first, id: id) {
                return found
            }
            return findSplitRecursively(in: splitState.second, id: id)
        }
    }

    private struct ResizeTarget {
        let split: SplitState
        let bounds: CGRect
    }

    private func equalizeNode(_ node: SplitNode) -> Int {
        switch node {
        case .pane:
            return 1

        case .split(let splitState):
            let firstWeight = weight(splitState.first, matching: splitState.orientation)
            let secondWeight = weight(splitState.second, matching: splitState.orientation)
            let totalWeight = max(1, firstWeight + secondWeight)

            splitState.dividerPosition = CGFloat(firstWeight) / CGFloat(totalWeight)
            _ = equalizeNode(splitState.first)
            _ = equalizeNode(splitState.second)
            return totalWeight
        }
    }

    private func weight(_ node: SplitNode, matching orientation: SplitOrientation) -> Int {
        switch node {
        case .pane:
            return 1

        case .split(let splitState):
            if splitState.orientation == orientation {
                return weight(splitState.first, matching: orientation)
                    + weight(splitState.second, matching: orientation)
            }
            return 1
        }
    }

    private func resizeTarget(
        in node: SplitNode,
        containing paneId: PaneID,
        direction: NavigationDirection,
        bounds: CGRect,
        current: ResizeTarget?
    ) -> ResizeTarget? {
        switch node {
        case .pane(let pane):
            return pane.id == paneId ? current : nil

        case .split(let splitState):
            let candidate = splitState.orientation == Self.resizeOrientation(for: direction)
                ? ResizeTarget(split: splitState, bounds: bounds)
                : current
            let childBounds = Self.childBounds(for: splitState, in: bounds)

            if splitState.first.findPane(paneId) != nil {
                return resizeTarget(
                    in: splitState.first,
                    containing: paneId,
                    direction: direction,
                    bounds: childBounds.first,
                    current: candidate
                )
            }

            if splitState.second.findPane(paneId) != nil {
                return resizeTarget(
                    in: splitState.second,
                    containing: paneId,
                    direction: direction,
                    bounds: childBounds.second,
                    current: candidate
                )
            }

            return nil
        }
    }

    private static func resizeOrientation(for direction: NavigationDirection) -> SplitOrientation {
        switch direction {
        case .left, .right:
            return .horizontal
        case .up, .down:
            return .vertical
        }
    }

    private static func childBounds(
        for splitState: SplitState,
        in bounds: CGRect
    ) -> (first: CGRect, second: CGRect) {
        switch splitState.orientation {
        case .horizontal:
            return (
                first: CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width * splitState.dividerPosition,
                    height: bounds.height
                ),
                second: CGRect(
                    x: bounds.minX + bounds.width * splitState.dividerPosition,
                    y: bounds.minY,
                    width: bounds.width * (1 - splitState.dividerPosition),
                    height: bounds.height
                )
            )

        case .vertical:
            return (
                first: CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: bounds.width,
                    height: bounds.height * splitState.dividerPosition
                ),
                second: CGRect(
                    x: bounds.minX,
                    y: bounds.minY + bounds.height * splitState.dividerPosition,
                    width: bounds.width,
                    height: bounds.height * (1 - splitState.dividerPosition)
                )
            )
        }
    }

    private static func clampDividerPosition(_ position: CGFloat) -> CGFloat {
        min(max(position, 0.1), 0.9)
    }

    private func clearInvalidZoomedPane() {
        guard let zoomedPaneId,
              rootNode?.findPane(zoomedPaneId) == nil else { return }
        self.zoomedPaneId = nil
    }

    /// Get all split states in the tree
    var allSplits: [SplitState] {
        guard let rootNode else { return [] }
        return collectSplits(from: rootNode)
    }

    private func collectSplits(from node: SplitNode) -> [SplitState] {
        switch node {
        case .pane:
            return []
        case .split(let splitState):
            return [splitState] + collectSplits(from: splitState.first) + collectSplits(from: splitState.second)
        }
    }
}
