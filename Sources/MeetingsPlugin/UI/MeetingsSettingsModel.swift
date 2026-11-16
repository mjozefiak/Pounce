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
    /// Called when the speech model, its place or the microphone access changed, so the plugin can tell the shell
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
    /// The saved "Your name" (empty when unset). Change it through `saveSelfName(_:)`.
    private(set) var selfName: String
    /// Why the last typed name was not saved; cleared by the next save.
    private(set) var selfNameError: MeetingsSettings.SelfNameError?
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
    var suggestionStatus = MeetingDetector.Status.off
    var mutedApps: [SuggestionApp] = []
    var extraApps: [SuggestionApp] = []
    var extraAppError: ExtraAppError?
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
    @ObservationIgnored private let accountName: () -> String

    init(
        settings: MeetingsSettings, library: MeetingsLibrary, privacy: MeetingsPrivacyActions,
        speech: MeetingsModelCardModel, diarization: MeetingsModelCardModel, systemAudioTest: SystemAudioTestModel,
        notes: NotesSettingsModel, speechPackages: [ModelPackage] = ModelCatalog.all,
        authorizer: any MicrophoneAuthorizer,
        listDevices: @escaping () -> [MicrophoneCapture.InputDevice] = MicrophoneCapture.inputDevices,
        openURL: @escaping @MainActor (URL) -> Void,
        accountName: @escaping () -> String = { NSFullUserName() }
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
        self.accountName = accountName
        speechPackageID = speech.package.id
        inputDevice = settings.inputDevice
        voiceProcessing = settings.voiceProcessing
        consentReminder = settings.consentReminder
        retentionDays = settings.retentionDays
        selfName = settings.selfName
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
        // The Ready banner names the model: the shell reads it again even when the new one is in the same place.
        onStatusChange?()
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

    // MARK: Your name

    /// The first word of the macOS account's full name, offered as "Use: <name>" when it is a valid name that
    /// is not the saved one. Nothing is saved until the user clicks it.
    var suggestedSelfName: String? {
        guard let word = accountName().split(whereSeparator: \.isWhitespace).first.map(String.init),
            case .success(let name) = MeetingsSettings.validatedSelfName(word), !name.isEmpty, name != selfName
        else { return nil }
        return name
    }

    /// Saves the typed name (the field's submit, or the suggestion's button). A generic word or a name over
    /// 60 characters is rejected and `selfNameError` says why; an empty one clears the name. When the saved
    /// value changes, the notes that used it are marked `stale` so the user regenerates them.
    @discardableResult
    func saveSelfName(_ text: String) -> Bool {
        switch settings.setSelfName(text) {
        case .failure(let error):
            selfNameError = error
            return false
        case .success(let name):
            selfNameError = nil
            guard name != selfName else { return true }
            selfName = name
            try? library.store?.markNotesStaleForSelfName()
            return true
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

    /// How many copies of meetings Notes keeps because the user edited or commented on them ("N copies in Notes are
    /// kept"). Read before a confirmation sheet opens (`refreshKeptCopies()`); 0 without Notes.
    private(set) var keptCopyCount = 0
    /// `PluginContext.keptNoteCopies` / `deleteKeptNoteCopies` for this plugin; the defaults mean "no Notes".
    @ObservationIgnored var keptCopies: @MainActor () async -> Int = { 0 }
    @ObservationIgnored var deleteKeptCopies: @MainActor () async -> Bool = { true }

    func refreshKeptCopies() async { keptCopyCount = await keptCopies() }

    /// Called after the pane's confirmation. `alsoDeleteKeptCopies` is the sheet's "Also delete kept copies"
    /// checkbox (off by default): the copies are removed through Notes ONLY when the box is ticked AND the library
    /// was cleared completely; the library is cleared first, never the other way round. The returned task is the
    /// copies' removal.
    @discardableResult
    func clearLibrary(alsoDeleteKeptCopies: Bool = false) -> Task<Void, Never>? {
        let cleared = run {
            let report = try privacy.clearLibrary()
            return (Self.removedMessage(report.removed), report.failed)
        }
        guard cleared, alsoDeleteKeptCopies else { return nil }
        return Task {
            if await !deleteKeptCopies() {
                privacyMessage = String(
                    localized: "The meetings were deleted, but some copies in Notes could not be removed.",
                    comment: "Meetings settings: Also delete kept copies failed after the library was cleared")
                privacyFailed = true
            }
            await refreshKeptCopies()
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
    @discardableResult
    private func run(_ action: () throws -> (message: String, failed: Int)) -> Bool {
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
            return result.failed == 0
        } catch {
            privacyMessage = String(
                localized: "The library could not be changed. Nothing was lost; try again.",
                comment: "Meetings settings: a privacy action failed")
            privacyFailed = true
            return false
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
