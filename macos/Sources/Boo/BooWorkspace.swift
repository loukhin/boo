import Foundation

struct WorkspaceID: Hashable, Identifiable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

@MainActor
final class BooWorkspace: Identifiable {
    let id: WorkspaceID
    let controller: BonsplitController
    var title: String
    var customTitle: String?

    init(
        id: WorkspaceID = WorkspaceID(),
        controller: BonsplitController,
        title: String,
        customTitle: String? = nil
    ) {
        self.id = id
        self.controller = controller
        self.title = title
        self.customTitle = customTitle
    }
}
