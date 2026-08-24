import AppKit
import AppIntents
import GhosttyKit

struct FocusTerminalIntent: AppIntent {
    static var title: LocalizedStringResource = "Focus Terminal"
    static var description = IntentDescription("Move focus to an existing terminal.")

    @Parameter(
        title: "Terminal",
        description: "The terminal to focus.",
    )
    var terminal: TerminalEntity

#if compiler(>=6.2)
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes = .background
#endif

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await requestIntentPermission() else {
            throw GhosttyIntentError.permissionDenied
        }

        guard let surfaceView = terminal.surfaceView else {
            throw GhosttyIntentError.surfaceNotFound
        }

        if let controller = BaseTerminalController.controller(owning: surfaceView) {
            controller.focusSurface(surfaceView)
        } else if let controller = BooController.controller(owning: surfaceView) {
            controller.state.presentSurface(surfaceView)
        }
        return .result()
    }
}
