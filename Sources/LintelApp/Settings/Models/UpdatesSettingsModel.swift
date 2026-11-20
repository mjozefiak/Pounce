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
        guard let controller, controller.isRunning else {
            isAvailable = false
            automaticChecks = false
            automaticDownloads = false
            includeBeta = false
            canCheckNow = false
            runsPreRelease = false
            return
        }
        isAvailable = true
        automaticChecks = controller.automaticallyChecks
        automaticDownloads = controller.automaticallyDownloads
        includeBeta = controller.includesBeta
        canCheckNow = controller.canCheckForUpdates
        runsPreRelease = controller.runningVersionIsPreRelease
    }

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
