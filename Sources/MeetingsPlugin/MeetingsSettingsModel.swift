import Foundation
import Observation
import PounceSpeech

/// What Settings → Meetings and the `meetings.setup` step show and do. Shared by both screens, so a model
/// downloaded in one shows as downloaded in the other.
@MainActor @Observable
final class MeetingsSettingsModel {
    private(set) var microphone = MicrophoneAccess.notDetermined
    private(set) var devices: [MicrophoneCapture.InputDevice] = []
    var inputDevice: String? {
        didSet { settings.setInputDevice(inputDevice) }
    }
    var voiceProcessing: Bool {
        didSet { settings.setVoiceProcessing(voiceProcessing) }
    }
    var consentReminder: Bool {
        didSet { settings.setConsentReminder(consentReminder) }
    }
    /// 0 keeps meetings until the user deletes them.
    var retentionDays: Int {
        didSet { settings.setRetentionDays(retentionDays) }
    }
    private(set) var privacyMessage: String?
    private(set) var privacyFailed = false

    let speech: MeetingsModelCardModel
    let diarization: MeetingsModelCardModel
    let systemAudioTest: SystemAudioTestModel
    /// The speech models to choose from.
    let speechPackages: [ModelPackage]
    private(set) var speechPackageID: String

    @ObservationIgnored private let settings: MeetingsSettings
    @ObservationIgnored private let library: MeetingsLibrary
    @ObservationIgnored private let privacy: MeetingsPrivacyActions
    @ObservationIgnored private let authorizer: any MicrophoneAuthorizer
    @ObservationIgnored private let listDevices: () -> [MicrophoneCapture.InputDevice]
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    init(
        settings: MeetingsSettings, library: MeetingsLibrary, privacy: MeetingsPrivacyActions,
        speech: MeetingsModelCardModel, diarization: MeetingsModelCardModel, systemAudioTest: SystemAudioTestModel,
        speechPackages: [ModelPackage] = ModelCatalog.all, authorizer: any MicrophoneAuthorizer,
        listDevices: @escaping () -> [MicrophoneCapture.InputDevice] = MicrophoneCapture.inputDevices,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.settings = settings
        self.library = library
        self.privacy = privacy
        self.speech = speech
        self.diarization = diarization
        self.systemAudioTest = systemAudioTest
        self.speechPackages = speechPackages
        self.authorizer = authorizer
        self.listDevices = listDevices
        self.openURL = openURL
        speechPackageID = speech.package.id
        inputDevice = settings.inputDevice
        voiceProcessing = settings.voiceProcessing
        consentReminder = settings.consentReminder
        retentionDays = settings.retentionDays
    }

    // MARK: Refresh

    /// Re-reads the models, the microphone and the device list (the screens call it when they appear).
    func refresh() async {
        microphone = authorizer.status()
        devices = listDevices()
        await speech.refresh()
        await diarization.refresh()
    }

    // MARK: Speech engine

    /// The Whisper engine needs a pinned language; the Parakeet engine detects it.
    var usesPinnedLanguage: Bool { speechPackageID == ModelCatalog.whisperLargeV3Turbo.id }

    var speechLanguage: String {
        get { settings.speechLanguage }
        set { settings.setSpeechLanguage(newValue) }
    }

    func selectSpeechModel(_ id: String) {
        guard id != speechPackageID, let chosen = speechPackages.first(where: { $0.id == id }) else { return }
        speechPackageID = id
        settings.setSpeechModelID(id)
        speech.use(chosen)
    }

    // MARK: Microphone

    /// "Allow Microphone": the user's click, so the system prompt may appear. Never called otherwise.
    func requestMicrophone() {
        Task {
            _ = await authorizer.requestAccess()
            microphone = authorizer.status()
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            openURL(url)
        }
    }

    func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            openURL(url)
        }
    }

    // MARK: Privacy

    /// Both destructive actions need an open library.
    var canChangeLibrary: Bool { library.status == .ready }

    /// Called after the pane's confirmation.
    func clearLibrary() {
        run {
            let report = try privacy.clearLibrary()
            return String(
                localized: "Removed \(report.removed) meetings and their audio.",
                comment: "Meetings settings: result of Clear Library")
        }
    }

    /// Called after the pane's confirmation.
    func deleteTemporaryRecordings() {
        run {
            let report = try privacy.deleteTemporaryRecordings()
            return String(
                localized: "Deleted the audio of \(report.removed) interrupted meetings.",
                comment: "Meetings settings: result of Delete Temporary Recordings")
        }
    }

    private func run(_ action: () throws -> String) {
        do {
            privacyMessage = try action()
            privacyFailed = false
        } catch {
            privacyMessage = String(
                localized: "The library could not be changed. Nothing was lost; try again.",
                comment: "Meetings settings: a privacy action failed")
            privacyFailed = true
        }
    }

    // MARK: Setup step

    var setupProgress: MeetingsSetupProgress {
        MeetingsSetupProgress(
            microphone: microphone, systemAudioVerified: systemAudioTest.isVerified,
            speechInstalled: speech.isInstalled, diarizationInstalled: diarization.isInstalled)
    }
}

/// Which parts of the `meetings.setup` step are finished. Every part can be skipped; the shell tracks the
/// step as a whole (`app.onboarding.completedSteps`), so this only decides the checkmarks.
struct MeetingsSetupProgress: Equatable {
    enum Part: CaseIterable {
        case microphone
        case systemAudio
        case models
    }

    var microphone: MicrophoneAccess
    /// The system audio test heard its signal in this session.
    var systemAudioVerified: Bool
    var speechInstalled: Bool
    var diarizationInstalled: Bool

    func isDone(_ part: Part) -> Bool {
        switch part {
        case .microphone: microphone == .granted
        case .systemAudio: systemAudioVerified
        case .models: speechInstalled && diarizationInstalled
        }
    }

    var isComplete: Bool { Part.allCases.allSatisfy(isDone) }
}
