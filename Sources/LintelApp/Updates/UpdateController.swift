import Foundation
import LintelKit
import os

/// Owns the updater: asks `UpdaterStartPolicy`, and only on `.start` creates the real `UpdateChecking` and starts
/// it. Until then nothing of the update framework is created, so no request is made and no default is written.
final class UpdateController {
    /// Starts a repeating call of `tick` every `interval` seconds and returns the closure that stops it (a seam so
    /// tests do not sleep).
    typealias PollStarter = (_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void

    enum State: Equatable {
        case idle
        case off(UpdaterStartPolicy.Refusal)
        case running
        case failed
    }

    private(set) var state: State = .idle
    /// The version a background check found and the user has not looked at yet; `nil` when there is nothing to
    /// remind about. The menu bar shows a badge and an "Update available" item while it is set (spec Step 4.4).
    private(set) var pendingVersion: String? {
        didSet { if pendingVersion != oldValue { onReminderChange?(pendingVersion) } }
    }
    /// Called when `pendingVersion` changes.
    var onReminderChange: ((String?) -> Void)?
    private var checker: (any UpdateChecking)?
    private let facts: UpdaterStartPolicy.Facts
    private let settings: any SettingsStore
    private let runningVersion: String
    private let makeChecker: () -> any UpdateChecking
    private let isBusy: () -> Bool
    private let startPolling: PollStarter
    private let pollInterval: TimeInterval
    /// Stops the repeating busy check; non-nil only while a relaunch is held back.
    private var stopPolling: (() -> Void)?
    private let logger = Logger(subsystem: "com.lintelapp", category: "updates")

    init(
        facts: UpdaterStartPolicy.Facts,
        settings: any SettingsStore,
        runningVersion: String,
        isBusy: @escaping () -> Bool = { false },
        pollInterval: TimeInterval = 5,
        startPolling: @escaping PollStarter = UpdateController.timerPoll,
        makeChecker: @escaping () -> any UpdateChecking
    ) {
        self.isBusy = isBusy
        self.pollInterval = pollInterval
        self.startPolling = startPolling
        self.facts = facts
        self.settings = settings
        self.runningVersion = runningVersion
        self.makeChecker = makeChecker
    }

    /// Starts the updater when the policy allows it. Safe to call more than once: only the first call acts.
    func startIfAllowed() {
        guard state == .idle else { return }
        switch UpdaterStartPolicy.decide(facts) {
        case .refuse(let reason):
            state = .off(reason)
            logger.info("Updater off: \(reason.rawValue, privacy: .public)")
        case .start:
            let checker = makeChecker()
            checker.allowedChannels = UpdateChannel.allowed(
                includeBeta: UpdateChannel.includeBeta(settings: settings, runningVersion: runningVersion))
            checker.onEvent = { [weak self] event in self?.handle(event) }
            checker.shouldPostponeRelaunch = { [weak self] in self?.isBusy() ?? false }
            do {
                try checker.start()
                self.checker = checker
                state = .running
            } catch {
                state = .failed
                logger.error("Updater did not start: \(String(describing: error), privacy: .public)")
            }
        }
    }

    var canCheckForUpdates: Bool { checker?.canCheckForUpdates ?? false }

    func checkForUpdates() {
        checker?.checkForUpdates()
    }

    private func handle(_ event: UpdateEvent) {
        switch event {
        case .foundInBackground(let version): pendingVersion = version
        case .reminderNoLongerNeeded: pendingVersion = nil
        case .relaunchPostponed: beginPolling()
        }
    }

    /// Repeats `busyStateChanged()` while a relaunch is held back, and only then: no timer exists otherwise.
    private func beginPolling() {
        guard stopPolling == nil else { return }
        stopPolling = startPolling(pollInterval) { [weak self] in self?.busyStateChanged() }
    }

    private func endPolling() {
        stopPolling?()
        stopPolling = nil
    }

    /// Starts a repeating `tick` on the main run loop and returns the closure that stops it.
    static let timerPoll: PollStarter = { interval, tick in
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        return { timer.invalidate() }
    }

    /// Whether an install is waiting for a recording or processing to end (spec Step 4.6).
    var hasPostponedRelaunch: Bool { checker?.hasPostponedRelaunch ?? false }

    /// Call when a recording or processing ended: a held-back relaunch goes on once nothing is busy.
    func busyStateChanged() {
        guard let checker, checker.hasPostponedRelaunch else {
            endPolling()
            return
        }
        guard !isBusy() else { return }
        endPolling()
        checker.resumePostponedRelaunch()
    }
}

extension UpdateController {
    /// The controller for this process: facts from the main bundle, the real Sparkle checker.
    static func live(settings: any SettingsStore, isBusy: @escaping () -> Bool = { false }) -> UpdateController {
        let bundle = Bundle.main
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let facts = UpdaterStartPolicy.Facts(
            isDebugBuild: isDebug,
            bundleURL: bundle.bundleURL,
            // Not read in DEBUG builds, which the policy refuses first anyway.
            teamIdentifier: isDebug ? nil : BundleSignature.teamIdentifier(of: bundle.bundleURL),
            publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            feedURL: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
        return UpdateController(
            facts: facts,
            settings: settings,
            runningVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            isBusy: isBusy,
            makeChecker: { SparkleUpdateChecker() }
        )
    }
}
