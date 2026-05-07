import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Boo does not have its own appcast yet. Returning nil makes Sparkle
        // no-op any check (automatic or menu-driven) instead of phoning home
        // to ghostty's servers and offering to replace Boo.app with a signed
        // Ghostty.app release.
        //
        // Restore channel-based URL selection once a Boo-owned appcast is
        // published (see `dist/macos/RELEASE.md` for the signing flow). The
        // original ghostty routing looked like:
        //
        //     switch appDelegate.ghostty.config.autoUpdateChannel {
        //     case .tip:    return "https://tip.files.ghostty.org/appcast.xml"
        //     case .stable: return "https://release.files.ghostty.org/appcast.xml"
        //     }
        return nil
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            isAutoUpdate: true,
            retryTerminatingApplication: immediateInstallHandler,
            dismiss: { [weak viewModel] in
                viewModel?.state = .idle
            }
        ))
        return true
    }
}
