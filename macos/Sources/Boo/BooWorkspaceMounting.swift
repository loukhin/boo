import Foundation

@MainActor
final class BooWorkspaceMounting {
    private let recentMountedWorkspaceLimit: Int
    private var recentlyActiveWorkspaceIds: [WorkspaceID] = []
    private var pendingWorkspaceActivationId: WorkspaceID?

    init(recentMountedWorkspaceLimit: Int = 2) {
        self.recentMountedWorkspaceLimit = recentMountedWorkspaceLimit
    }

    func canActivateNow(
        id: WorkspaceID,
        activeWorkspaceId: WorkspaceID?,
        mountedWorkspaceIds: Set<WorkspaceID>,
        shouldFocus: Bool
    ) -> Bool {
        activeWorkspaceId == id || mountedWorkspaceIds.contains(id) || !shouldFocus
    }

    func prepareColdActivation(id: WorkspaceID) {
        pendingWorkspaceActivationId = id
    }

    func isPendingActivation(_ id: WorkspaceID) -> Bool {
        pendingWorkspaceActivationId == id
    }

    func clearPendingActivation(_ id: WorkspaceID) {
        guard pendingWorkspaceActivationId == id else { return }
        pendingWorkspaceActivationId = nil
    }

    func recordActivation(from previousId: WorkspaceID?, to newId: WorkspaceID) {
        guard previousId != newId else { return }

        if let previousId {
            recentlyActiveWorkspaceIds.removeAll { $0 == previousId }
            recentlyActiveWorkspaceIds.insert(previousId, at: 0)
        }
    }

    func mountedWorkspaceIds(
        workspaceIds: [WorkspaceID],
        activeWorkspaceId: WorkspaceID?,
        keeping extraIds: Set<WorkspaceID> = []
    ) -> Set<WorkspaceID> {
        let validIds = Set(workspaceIds)
        recentlyActiveWorkspaceIds = recentlyActiveWorkspaceIds.filter { validIds.contains($0) }
        if let pendingWorkspaceActivationId, !validIds.contains(pendingWorkspaceActivationId) {
            self.pendingWorkspaceActivationId = nil
        }

        var mounted = extraIds.intersection(validIds)
        if let pendingWorkspaceActivationId, validIds.contains(pendingWorkspaceActivationId) {
            mounted.insert(pendingWorkspaceActivationId)
        }

        if let activeWorkspaceId,
           let activeIndex = workspaceIds.firstIndex(of: activeWorkspaceId) {
            mounted.insert(activeWorkspaceId)

            if activeIndex > workspaceIds.startIndex {
                mounted.insert(workspaceIds[workspaceIds.index(before: activeIndex)])
            }
            let nextIndex = workspaceIds.index(after: activeIndex)
            if nextIndex < workspaceIds.endIndex {
                mounted.insert(workspaceIds[nextIndex])
            }
        }

        for id in recentlyActiveWorkspaceIds.prefix(recentMountedWorkspaceLimit) {
            mounted.insert(id)
        }

        return mounted
    }
}
