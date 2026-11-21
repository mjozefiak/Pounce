#if DEBUG
import Foundation
import LintelKit

/// The updater of a QA run with `--qa-update-available`: it creates nothing of the update framework and makes no
/// request; on start it reports (when it has a version) that a background check found the given version.
final class QAUpdateChecker: UpdateChecking {
    private let version: String?
    private(set) var checks = 0

    init(version: String?) {
        self.version = version
    }

    var allowedChannels: Set<String> = []
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var onEvent: ((UpdateEvent) -> Void)?
    var shouldPostponeRelaunch: (() -> Bool)?
    var canCheckForUpdates: Bool { true }
    var hasPostponedRelaunch: Bool { false }

    func start() throws {
        if let version { onEvent?(.foundInBackground(version: version)) }
    }

    /// The real checker would bring the update window forward, which ends the reminder.
    func checkForUpdates() {
        checks += 1
        onEvent?(.reminderNoLongerNeeded)
    }

    func resumePostponedRelaunch() {}

    /// A controller whose policy says "start" (the facts of an installed, signed release build) over this fake.
    static func controller(
        version: String?, beta: Bool = false, settings: any SettingsStore, isBusy: @escaping () -> Bool = { false }
    ) -> UpdateController {
        let home = URL(filePath: "/Users/qa", directoryHint: .isDirectory)
        return UpdateController(
            facts: UpdaterStartPolicy.Facts(
                isDebugBuild: false,
                bundleURL: URL(filePath: "/Applications/Lintel.app", directoryHint: .isDirectory),
                teamIdentifier: "QA",
                publicKey: "qa",
                feedURL: "https://lintelapp.com/appcast.xml",
                homeDirectory: home
            ),
            settings: settings,
            runningVersion: beta ? "0.0.0-beta.1" : "0.0.0",
            isBusy: isBusy,
            makeChecker: { QAUpdateChecker(version: version) }
        )
    }
}
#endif

#if DEBUG
/// The QA flag behind `--qa-updates pending`: the welcome flow counts as open until it is cleared.
@MainActor
final class QAWelcomePending {
    var value = true
}
#endif
