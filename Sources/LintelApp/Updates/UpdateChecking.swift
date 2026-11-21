import Foundation

/// What the update framework tells the shell.
nonisolated enum UpdateEvent: Equatable, Sendable {
    /// A scheduled (background) check found an update. No window was shown: the shell shows a quiet reminder.
    case foundInBackground(version: String)
    /// The user saw the update (its window came into focus) or the update session ended: the reminder goes away.
    case reminderNoLongerNeeded
    /// An update is ready to install and the relaunch is being held back because Lintel is busy: the controller
    /// polls until nothing is busy (there is no "busy ended" event in the plugin contract).
    case relaunchPostponed
}

/// The port between the shell and the update framework (Sparkle), so that nothing but `SparkleUpdateChecker`
/// imports it and tests, DEBUG builds and QA runs use a fake (spec `2026-11-19-updates-and-open-source-hygiene`,
/// Steps 4.3, 4.4 and 4.6; `docs/decisions/0012-distribution-and-updates.md`).
protocol UpdateChecking: AnyObject {
    /// Starts the updater. Nothing is requested from the network and no default is written before this call.
    func start() throws

    /// Whether a check can begin now (false while one is running or before `start()`).
    var canCheckForUpdates: Bool { get }

    /// A check the user asked for: it may show a window. Also brings a found update into focus.
    func checkForUpdates()

    /// The channels offered besides the default one (`UpdateChannel.allowed`). Read on every check.
    var allowedChannels: Set<String> { get set }

    /// Called on the main actor for every `UpdateEvent`.
    var onEvent: ((UpdateEvent) -> Void)? { get set }

    /// Asked when an update is ready to install and relaunch: `true` means "not now" (a recording or processing is
    /// running). The checker then keeps the relaunch until `resumePostponedRelaunch()`.
    var shouldPostponeRelaunch: (() -> Bool)? { get set }

    /// Whether a relaunch is being held back.
    var hasPostponedRelaunch: Bool { get }

    /// Lets a held-back relaunch go on. Does nothing when there is none.
    func resumePostponedRelaunch()
}
