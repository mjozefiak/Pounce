import Foundation
import Sparkle

/// `UpdateChecking` over Sparkle's standard updater and its standard windows. The only file that imports Sparkle.
/// Created only after `UpdaterStartPolicy` said `.start`.
///
/// Gentle reminders (Sparkle's term): a scheduled check never opens a window. The delegate declines to let the
/// standard driver show a scheduled update and reports it as `UpdateEvent.foundInBackground`; the window opens when
/// the user asks (`checkForUpdates()`).
final class SparkleUpdateChecker: NSObject, UpdateChecking, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    var allowedChannels: Set<String> = []
    var onEvent: ((UpdateEvent) -> Void)?
    var shouldPostponeRelaunch: (() -> Bool)?
    private var controller: SPUStandardUpdaterController?
    private var postponedInstall: (() -> Void)?

    func start() throws {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        try controller.updater.start()
        self.controller = controller
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set { controller?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var hasPostponedRelaunch: Bool { postponedInstall != nil }

    func resumePostponedRelaunch() {
        guard let install = postponedInstall else { return }
        postponedInstall = nil
        install()
    }

    // MARK: SPUUpdaterDelegate

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        allowedChannels
    }

    func updater(
        _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard shouldPostponeRelaunch?() == true else { return false }
        postponedInstall = installHandler
        onEvent?(.relaunchPostponed)
        return true
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Never: a scheduled check must not open a window or take focus.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        onEvent?(.foundInBackground(version: update.displayVersionString))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onEvent?(.reminderNoLongerNeeded)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onEvent?(.reminderNoLongerNeeded)
    }
}
