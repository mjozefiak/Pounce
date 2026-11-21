import Foundation
import Observation

/// What Settings → General → Updates shows. It mirrors the `UpdateController` (which is not observable) and is
/// refreshed on appear, after every change and once a second while the pane is on screen, so an answer to
/// Sparkle's permission question or the end of a check shows up without reopening the window.
@Observable
final class UpdatesSettingsModel {
    /// Set by `AppCoordinator.attach` once `LintelMain` made the updater; `nil` before that.
    var controller: UpdateController? {
        didSet { refresh() }
    }

    let version: String
    let build: String

    private(set) var isAvailable = false
    /// The updater is held back only until the welcome flow closes: the group is shown, its controls disabled.
    private(set) var isWaitingForWelcome = false
    private(set) var automaticChecks = false
    private(set) var automaticDownloads = false
    private(set) var includeBeta = false
    private(set) var canCheckNow = false
    private(set) var runsPreRelease = false

    init(version: String, build: String, controller: UpdateController? = nil) {
        self.version = version
        self.build = build
        self.controller = controller
        refresh()
    }

    static func forMainBundle(_ bundle: Bundle = .main) -> UpdatesSettingsModel {
        UpdatesSettingsModel(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    func refresh() {
        isWaitingForWelcome = controller?.waitingForWelcome ?? false
        guard let controller, controller.isRunning else {
            isAvailable = false
            automaticChecks = false
            automaticDownloads = false
            canCheckNow = false
            // While waiting for the welcome these come from sources that write nothing, so the group does not
            // flip when the updater starts.
            includeBeta = isWaitingForWelcome ? (controller?.peekedIncludesBeta ?? false) : false
            runsPreRelease = isWaitingForWelcome ? (controller?.runningVersionIsPreRelease ?? false) : false
            return
        }
        isAvailable = true
        automaticChecks = controller.automaticallyChecks
        automaticDownloads = controller.automaticallyDownloads
        includeBeta = controller.includesBeta
        canCheckNow = controller.canCheckForUpdates
        runsPreRelease = controller.runningVersionIsPreRelease
    }

    /// Whether the group shows its controls (live or waiting for the welcome) instead of the "unavailable" line.
    var showsControls: Bool { isAvailable || isWaitingForWelcome }

    func setAutomaticChecks(_ value: Bool) {
        controller?.automaticallyChecks = value
        refresh()
    }

    func setAutomaticDownloads(_ value: Bool) {
        controller?.automaticallyDownloads = value
        refresh()
    }

    func setIncludeBeta(_ value: Bool) {
        controller?.setIncludesBeta(value)
        refresh()
    }

    func checkNow() {
        controller?.checkForUpdates()
        refresh()
    }
}
