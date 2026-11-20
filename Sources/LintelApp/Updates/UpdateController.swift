import Foundation
import LintelKit
import os

/// Owns the updater: asks `UpdaterStartPolicy`, and only on `.start` creates the real `UpdateChecking` and starts
/// it. Until then nothing of the update framework is created, so no request is made and no default is written.
final class UpdateController {
    enum State: Equatable {
        case idle
        case off(UpdaterStartPolicy.Refusal)
        case running
        case failed
    }

    private(set) var state: State = .idle
    private var checker: (any UpdateChecking)?
    private let facts: UpdaterStartPolicy.Facts
    private let settings: any SettingsStore
    private let runningVersion: String
    private let makeChecker: () -> any UpdateChecking
    private let logger = Logger(subsystem: "com.lintelapp", category: "updates")

    init(
        facts: UpdaterStartPolicy.Facts,
        settings: any SettingsStore,
        runningVersion: String,
        makeChecker: @escaping () -> any UpdateChecking
    ) {
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
}

extension UpdateController {
    /// The controller for this process: facts from the main bundle, the real Sparkle checker.
    static func live(settings: any SettingsStore) -> UpdateController {
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
            makeChecker: { SparkleUpdateChecker() }
        )
    }
}
