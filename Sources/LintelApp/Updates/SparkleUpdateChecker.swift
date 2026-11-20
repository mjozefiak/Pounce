import Foundation
import Sparkle

/// `UpdateChecking` over Sparkle's standard updater and its standard windows. The only file that imports Sparkle.
/// Created only after `UpdaterStartPolicy` said `.start`.
final class SparkleUpdateChecker: NSObject, UpdateChecking, SPUUpdaterDelegate {
    var allowedChannels: Set<String> = []
    private var controller: SPUStandardUpdaterController?

    func start() throws {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        try controller.updater.start()
        self.controller = controller
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels
    }
}
