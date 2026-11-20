import Foundation

/// The port between the shell and the update framework (Sparkle), so that nothing but `SparkleUpdateChecker`
/// imports it and tests, DEBUG builds and QA runs use a fake (spec `2026-11-19-updates-and-open-source-hygiene`,
/// Step 4.3; `docs/decisions/0012-distribution-and-updates.md`).
protocol UpdateChecking: AnyObject {
    /// Starts the updater. Nothing is requested from the network and no default is written before this call.
    func start() throws

    /// Whether a check can begin now (false while one is running or before `start()`).
    var canCheckForUpdates: Bool { get }

    /// A check the user asked for: it may show a window.
    func checkForUpdates()

    /// The channels offered besides the default one (`UpdateChannel.allowed`). Read on every check.
    var allowedChannels: Set<String> { get set }
}
