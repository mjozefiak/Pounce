import AppKit
import Foundation

/// Lets the suggestion HUD's buttons reach the detector, which exists while the plugin is active.
@MainActor
final class SuggestionRelay {
    var detector: MeetingDetector?
}

extension MeetingsPlugin {
    /// Builds the detector for this activation. It does not listen yet: `startDetector` decides that from the
    /// setting.
    func makeDetector() -> MeetingDetector {
        var dependencies = MeetingDetector.Dependencies(
            observer: CoreAudioProcessObserver(), presenter: suggestionHUD, clock: DetectorClock(context.clock),
            settings: settings,
            isBusy: { [weak self] in
                guard let self else { return false }
                return activity.isActive || (controller?.isBusy ?? false) || lingeringController != nil
            },
            startRecording: { [weak self] bundleID in self?.controller?.start(fromSuggestionOf: bundleID) },
            stopRecording: { [weak self] in self?.controller?.stop() },
            appName: { MeetingLibraryPresentation.installedAppName($0) ?? $0 },
            ownBundleID: Bundle.main.bundleIdentifier,
            statusChanged: { [weak self] status in self?.ui.model.detectorStatusChanged(status) },
            logger: context.logger)
        adjustDetectorDependencies?(&dependencies)
        let detector = MeetingDetector(dependencies)
        self.detector = detector
        suggestionRelay.detector = detector
        return detector
    }

    /// Starts listening only when the user turned suggestions on.
    func startDetector(_ detector: MeetingDetector) {
        detector.reconcile(enabled: settings.suggestMeetings)
    }

    /// The plugin is switched off: the listeners go, the HUD goes.
    func stopDetector() {
        detector?.stop()
        detector = nil
        suggestionRelay.detector = nil
    }

    /// The setting (or a list) changed in the pane or the setup step.
    func wireSuggestionSettings() {
        ui.model.suggestionsChanged = { [weak self] in
            guard let self, let detector else { return }
            detector.reconcile(enabled: settings.suggestMeetings)
        }
    }
}
