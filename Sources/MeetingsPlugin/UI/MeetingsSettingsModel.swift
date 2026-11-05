import Foundation
import LintelSpeech
import Observation

/// What Settings → Meetings and the `meetings.setup` step show and do. Shared by both screens, so a model
/// downloaded in one shows as downloaded in the other.
@MainActor @Observable
final class MeetingsSettingsModel {
    private(set) var microphone = MicrophoneAccess.notDetermined {
        didSet { if microphone != oldValue { onStatusChange?() } }
    }
    /// Called when the speech model's place or the microphone access changed, so the plugin can tell the shell
    /// to read its banner again (`PluginContext.resultsChanged`).
    @ObservationIgnored var onStatusChange: (@MainActor () -> Void)?
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
    /// 0 keeps meetings until the user deletes them. Change it through `selectRetention(_:)`: a shorter
    /// period that would delete meetings waits for a confirmation.
    private(set) var retentionDays: Int {
        didSet { settings.setRetentionDays(retentionDays) }
    }
    /// A shorter retention waiting for the user's confirmation, with how many meetings it deletes now.
    private(set) var pendingRetention: PendingRetention?
    private(set) var privacyMessage: String?
    private(set) var privacyFailed = false
    /// "Podpowiedzi spotkań" (Phase 3). Turning it on or off starts or stops the detector
    /// (`suggestionsChanged`); the lists are edited through the methods in `MeetingsSettingsModel+Suggestions`.
    var suggestMeetings: Bool {
        didSet {
            guard suggestMeetings != oldValue else { return }
            settings.setSuggestMeetings(suggestMeetings)
            suggestionsChanged()
        }
    }
    /// Whether the detector listens, cannot (the Core Audio process API is missing here) or is off.
    internal(set) var suggestionStatus = MeetingDetector.Status.off
    internal(set) var mutedApps: [SuggestionApp] = []
    internal(set) var extraApps: [SuggestionApp] = []
    internal(set) var extraAppError: ExtraAppError?
    @ObservationIgnored var suggestionsChanged: () -> Void = {}
    @ObservationIgnored var appName: @MainActor (String) -> String = {
        KnownMeetingApp.name(of: $0) ?? MeetingLibraryPresentation.installedAppName($0) ?? $0
    }

    let speech: MeetingsModelCardModel
    let diarization: MeetingsModelCardModel
    let systemAudioTest: SystemAudioTestModel
    let notes: NotesSettingsModel
    /// The speech models to choose from.
    let speechPackages: [ModelPackage]
    private(set) var speechPackageID: String

    @ObservationIgnored let settings: MeetingsSettings
    @ObservationIgnored private let library: MeetingsLibrary
    @ObservationIgnored private let privacy: MeetingsPrivacyActions
    @ObservationIgnored private let authorizer: any MicrophoneAuthorizer
    @ObservationIgnored private let listDevices: () -> [MicrophoneCapture.InputDevice]
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    init(
        settings: MeetingsSettings, library: MeetingsLibrary, privacy: MeetingsPrivacyActions,
        speech: MeetingsModelCardModel, diarization: MeetingsModelCardModel, systemAudioTest: SystemAudioTestModel,
        notes: NotesSettingsModel, speechPackages: [ModelPackage] = ModelCatalog.all,
        authorizer: any MicrophoneAuthorizer,
        listDevices: @escaping () -> [MicrophoneCapture.InputDevice] = MicrophoneCapture.inputDevices,
        openURL: @escaping @MainActor (URL) -> Void
    ) {
        self.settings = settings
        self.library = library
        self.privacy = privacy
        self.speech = speech
        self.diarization = diarization
        self.systemAudioTest = systemAudioTest
        self.notes = notes
        self.speechPackages = speechPackages
        self.authorizer = authorizer
        self.listDevices = listDevices
        self.openURL = openURL
        speechPackageID = speech.package.id
        inputDevice = settings.inputDevice
        voiceProcessing = settings.voiceProcessing
        consentReminder = settings.consentReminder
        retentionDays = settings.retentionDays
        suggestMeetings = settings.suggestMeetings
        reloadSuggestionLists()
        speech.onLocationChange = { [weak self] in self?.onStatusChange?() }
    }

    // MARK: Refresh

    /// Re-reads the models, the microphone and the device list (the screens call it when they appear).
    func refresh() async {
        microphone = authorizer.status()
        devices = listDevices()
        reloadSuggestionLists()
        await speech.refresh()
        await diarization.refresh()
        await notes.refresh()
    }

    /// Re-reads only what the Settings banner shows: the speech model's place and the microphone access. Reads
    /// files and the permission state, never asks for anything.
    func refreshStatus() async {
        microphone = authorizer.status()
        await speech.refresh()
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
        Task { await requestMicrophoneAccess() }
    }

    /// The same as `requestMicrophone()`, finished when the answer is known (the Settings banner's action).
    func requestMicrophoneAccess() async {
        _ = await authorizer.requestAccess()
        microphone = authorizer.status()
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

    // MARK: Retention

    struct PendingRetention: Equatable {
        var days: Int
        var affected: Int
    }

    /// The picker's choices, with the stored value added when it came from an older or hand-edited setting
    /// (the picker would show nothing selected otherwise). "Until I delete them" (0) stays last.
    func retentionChoices() -> [Int] {
        Self.choices(MeetingsSettings.retentionDayChoices, including: retentionDays)
    }

    static func choices(_ base: [Int], including value: Int) -> [Int] {
        guard !base.contains(value) else { return base }
        let finite = (base.filter { $0 > 0 } + [value]).sorted()
        return base.contains(0) ? finite + [0] : finite
    }

    /// The picker's action. A longer period (or none) applies at once; a shorter one that would delete
    /// meetings is held until `confirmRetention()`.
    func selectRetention(_ days: Int) {
        pendingRetention = nil
        guard days != retentionDays else { return }
        let shorter = days > 0 && (retentionDays == 0 || days < retentionDays)
        let affected = shorter ? library.meetingsExpiring(afterDays: days) : 0
        if affected > 0 {
            pendingRetention = PendingRetention(days: days, affected: affected)
        } else {
            retentionDays = days
        }
    }

    func cancelRetention() { pendingRetention = nil }

    /// Saves the shorter period and deletes the meetings it expires now.
    /// The setting changes at once (synchronously, so the dialog closing cannot cancel it); the deletion runs
    /// in the returned task.
    @discardableResult
    func confirmRetention() -> Task<Void, Never>? {
        guard let pending = pendingRetention else { return nil }
        pendingRetention = nil
        retentionDays = pending.days
        return Task {
            let deleted = await library.applyRetention()
            privacyMessage = Self.removedMessage(deleted)
            privacyFailed = false
        }
    }

    // MARK: Privacy

    /// Both destructive actions need an open library, and wait while a meeting is being finished (its row and
    /// audio are in use).
    var canChangeLibrary: Bool { library.status == .ready && !library.isProcessing }

    /// Called after the pane's confirmation.
    func clearLibrary() {
        run {
            let report = try privacy.clearLibrary()
            return (Self.removedMessage(report.removed), report.failed)
        }
    }

    /// Called after the pane's confirmation.
    func deleteTemporaryRecordings() {
        run {
            let report = try privacy.deleteTemporaryRecordings()
            return (
                String(
                    localized: "Deleted the audio of \(report.removed) interrupted meetings.",
                    comment: "Meetings settings: result of Delete Temporary Recordings"), report.failed
            )
        }
    }

    private static func removedMessage(_ count: Int) -> String {
        String(
            localized: "Removed \(count) meetings and their audio.",
            comment: "Meetings settings: result of Clear Library")
    }

    /// `failed` counts audio folders that are still on the disk; the result then says so instead of success.
    private func run(_ action: () throws -> (message: String, failed: Int)) {
        do {
            let result = try action()
            if result.failed > 0 {
                privacyMessage = String(
                    localized:
                        "\(result.failed) recordings could not be deleted. Close anything using them and try again.",
                    comment: "Meetings settings: some audio folders could not be removed")
                privacyFailed = true
            } else {
                privacyMessage = result.message
                privacyFailed = false
            }
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
