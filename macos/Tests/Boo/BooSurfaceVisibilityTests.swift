@testable import Ghostty
import Testing

@MainActor
struct BooSurfaceVisibilityTests {
    @Test func onlySelectedTabsInActiveWorkspaceAreVisible() throws {
        let first = BooWorkspace(controller: BonsplitController(), title: "First")
        let second = BooWorkspace(controller: BonsplitController(), title: "Second")
        let firstTab = try #require(first.controller.createTab())
        let otherTab = try #require(first.controller.createTab())
        let secondTab = try #require(second.controller.createTab())
        first.controller.selectTab(firstTab)

        #expect(BooState.visibleTabIds(
            in: [first, second], activeWorkspaceId: first.id, windowVisible: true
        ) == [firstTab])

        first.controller.selectTab(otherTab)
        #expect(BooState.visibleTabIds(
            in: [first, second], activeWorkspaceId: first.id, windowVisible: true
        ) == [otherTab])
        #expect(BooState.visibleTabIds(
            in: [first, second], activeWorkspaceId: second.id, windowVisible: true
        ) == [secondTab])
        #expect(BooState.visibleTabIds(
            in: [first, second], activeWorkspaceId: second.id, windowVisible: false
        ).isEmpty)
    }

    @Test func zoomHidesOtherPanesAndUnzoomRestoresThem() throws {
        let workspace = BooWorkspace(controller: BonsplitController(), title: "Split")
        let controller = workspace.controller
        let firstTab = try #require(controller.createTab())
        let firstPane = try #require(controller.focusedPaneId)
        let secondPane = try #require(controller.splitPane(orientation: .horizontal))
        let secondTab = try #require(controller.createTab(inPane: secondPane))

        #expect(BooState.visibleTabIds(
            in: [workspace], activeWorkspaceId: workspace.id, windowVisible: true
        ) == [firstTab, secondTab])
        #expect(controller.toggleZoomedPane(firstPane))
        #expect(BooState.visibleTabIds(
            in: [workspace], activeWorkspaceId: workspace.id, windowVisible: true
        ) == [firstTab])
        #expect(controller.toggleZoomedPane(firstPane))
        #expect(BooState.visibleTabIds(
            in: [workspace], activeWorkspaceId: workspace.id, windowVisible: true
        ) == [firstTab, secondTab])
    }
}
