import AppKit
import GhosttyKit

/// AppKit-restorable state for one Boo window.
///
/// This mirrors Ghostty's `TerminalRestorableState` mechanism but stores Boo's
/// workspace/Bonsplit hierarchy instead of Ghostty's native `SplitTree`.
final class BooRestorableState: TerminalRestorable {
    static var version: Int { 1 }

    let activeWorkspaceId: UUID?
    let focusedSurfaceId: UUID?
    let isWorkspaceSidebarVisible: Bool
    let workspaces: [BooWorkspaceRestorableState]

    @MainActor
    init(from state: BooState) {
        self.activeWorkspaceId = state.activeWorkspaceId?.id
        self.focusedSurfaceId = state.focusedSurface?.id
        self.isWorkspaceSidebarVisible = state.isWorkspaceSidebarVisible
        self.workspaces = state.workspaces.map { workspace in
            BooWorkspaceRestorableState(workspace: workspace, state: state)
        }
    }

    init(
        activeWorkspaceId: UUID?,
        focusedSurfaceId: UUID?,
        isWorkspaceSidebarVisible: Bool,
        workspaces: [BooWorkspaceRestorableState]
    ) {
        self.activeWorkspaceId = activeWorkspaceId
        self.focusedSurfaceId = focusedSurfaceId
        self.isWorkspaceSidebarVisible = isWorkspaceSidebarVisible
        self.workspaces = workspaces
    }

    required init(copy other: BooRestorableState) {
        self.activeWorkspaceId = other.activeWorkspaceId
        self.focusedSurfaceId = other.focusedSurfaceId
        self.isWorkspaceSidebarVisible = other.isWorkspaceSidebarVisible
        self.workspaces = other.workspaces
    }

    private enum CodingKeys: String, CodingKey {
        case activeWorkspaceId
        case focusedSurfaceId
        case isWorkspaceSidebarVisible
        case workspaces
    }

    required init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activeWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .activeWorkspaceId)
        self.focusedSurfaceId = try container.decodeIfPresent(UUID.self, forKey: .focusedSurfaceId)
        self.isWorkspaceSidebarVisible = try container.decode(Bool.self, forKey: .isWorkspaceSidebarVisible)
        self.workspaces = try container.decode([BooWorkspaceRestorableState].self, forKey: .workspaces)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(activeWorkspaceId, forKey: .activeWorkspaceId)
        try container.encodeIfPresent(focusedSurfaceId, forKey: .focusedSurfaceId)
        try container.encode(isWorkspaceSidebarVisible, forKey: .isWorkspaceSidebarVisible)
        try container.encode(workspaces, forKey: .workspaces)
    }
}

struct BooWorkspaceRestorableState: Codable {
    let id: UUID
    let title: String
    let customTitle: String?
    let bonsplit: BonsplitRestorableState
    let surfaces: [BooSurfaceRestorableState]

    @MainActor
    init(workspace: BooWorkspace, state: BooState) {
        self.id = workspace.id.id
        self.title = workspace.title
        self.customTitle = workspace.customTitle
        self.bonsplit = workspace.controller.restorableState()
        self.surfaces = workspace.controller.allTabIds.compactMap { tabId in
            guard let surface = state.surfaces[tabId] else { return nil }
            return BooSurfaceRestorableState(tabId: tabId, surface: surface)
        }
    }
}

struct BooSurfaceRestorableState: Codable {
    let tabId: TabID
    let surface: Ghostty.SurfaceView
}

final class BooWindowRestoration: NSObject, NSWindowRestoration {
    static let restorationIdentifier = NSUserInterfaceItemIdentifier(String(describing: BooWindowRestoration.self))

    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard identifier == restorationIdentifier else {
            completionHandler(nil, TerminalRestoreError.identifierUnknown)
            return
        }

        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            completionHandler(nil, TerminalRestoreError.delegateInvalid)
            return
        }

        if appDelegate.ghostty.config.windowSaveState == "never" {
            AppDelegate.logger.warning("skip Boo restoration: window-save-state=never")
            completionHandler(nil, nil)
            return
        }

        guard let state = BooRestorableState(coder: state) else {
            completionHandler(nil, TerminalRestoreError.stateDecodeFailed)
            return
        }

        let controller = BooController(ghostty: appDelegate.ghostty, restorableState: state)
        guard let window = controller.window else {
            completionHandler(nil, TerminalRestoreError.windowDidNotLoad)
            return
        }

        completionHandler(window, nil)
        controller.state.restoreFocus(toSurfaceWithId: state.focusedSurfaceId)
    }
}
