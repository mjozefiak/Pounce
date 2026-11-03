import Foundation
import PounceKit
import PounceSpeech

/// `plugins.meetings.*` (a protected contract from the release that ships it, `BACKWARD_COMPATIBILITY.md` §3).
/// Every key is declared here and nowhere else. `plugins.meetings.enabled` belongs to the host.
struct MeetingsSettings: Sendable {
    enum Key {
        static let speechModel = "speechModel"
        static let speechLanguage = "speechLanguage"
        static let speechModelFolder = "speechModelFolder"
        static let diarizationModelFolder = "diarizationModelFolder"
        static let inputDevice = "inputDevice"
        static let voiceProcessing = "voiceProcessing"
        static let systemAudio = "systemAudio"
        static let diarization = "diarization"
        static let consentReminder = "consentReminder"
        static let notesEnabled = "notesEnabled"
        static let builtInLLMModel = "builtInLLMModel"
        static let notesChunkTokens = "notesChunkTokens"
        static let notesReduceInputTokens = "notesReduceInputTokens"
        static let suggestMeetings = "suggestMeetings"
        static let suggestMutedBundleIDs = "suggestMutedBundleIDs"
        static let suggestExtraBundleIDs = "suggestExtraBundleIDs"
        static let retentionDays = "retentionDays"
        static let orphanAudioDays = "orphanAudioDays"
    }

    static let defaultSpeechModel = "parakeet-ultra"
    static let defaultRetentionDays = 90
    static let defaultOrphanAudioDays = 7
    static let defaultNotesChunkTokens = 3_000
    static let defaultNotesReduceInputTokens = 4_500
    /// Choices in Settings; 0 keeps meetings until the user deletes them.
    static let retentionDayChoices = [7, 30, 90, 180, 365, 0]

    private let settings: PluginSettings
    private let physicalMemory: UInt64

    init(_ settings: PluginSettings, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.settings = settings
        self.physicalMemory = physicalMemory
    }

    // MARK: Speech and audio

    var speechModelID: String { settings.string(Key.speechModel) ?? Self.defaultSpeechModel }

    /// `pl` or `en`; only the Whisper engine uses it.
    var speechLanguage: String { settings.string(Key.speechLanguage) == "en" ? "en" : "pl" }

    /// A folder the user downloaded the speech model into by hand.
    var speechModelFolder: URL? {
        guard let path = settings.string(Key.speechModelFolder), !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// A folder the user downloaded the diarization model into by hand.
    var diarizationModelFolder: URL? {
        guard let path = settings.string(Key.diarizationModelFolder), !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The input device's UID; `nil` follows the system's input.
    var inputDevice: String? {
        guard let uid = settings.string(Key.inputDevice), !uid.isEmpty else { return nil }
        return uid
    }

    /// Capture system audio (the remote side of a call) next to the microphone; off records the microphone only.
    var systemAudio: Bool { settings.bool(Key.systemAudio, default: true) }
    var voiceProcessing: Bool { settings.bool(Key.voiceProcessing, default: false) }
    var diarization: Bool { settings.bool(Key.diarization, default: true) }
    var consentReminder: Bool { settings.bool(Key.consentReminder, default: true) }

    // MARK: Notes

    var notesEnabled: Bool { settings.bool(Key.notesEnabled, default: false) }

    /// The built-in notes model; the default one (the smallest) when none is chosen, the stored id left the
    /// catalog or the model no longer fits this Mac's memory.
    var builtInLLMModel: LLMModel {
        let offered = LLMModelCatalog.available(physicalMemory: physicalMemory)
        return settings.string(Key.builtInLLMModel).flatMap { LLMModelCatalog.model(id: $0) }
            .flatMap { model in offered.contains { $0.id == model.id } ? model : nil } ?? LLMModelCatalog.defaultModel
    }

    /// The stored model is not the one in use: it left the catalog or does not fit this Mac's memory (the
    /// settings pane says so; the stored value stays, so it applies again on a Mac that fits it).
    var builtInLLMModelWasReplaced: Bool {
        guard let stored = settings.string(Key.builtInLLMModel) else { return false }
        return stored != builtInLLMModel.id
    }

    /// The models this Mac has the memory for; the default one alone when none qualifies.
    var offeredLLMModels: [LLMModel] {
        let offered = LLMModelCatalog.available(physicalMemory: physicalMemory)
        return offered.isEmpty ? [LLMModelCatalog.defaultModel] : offered
    }

    var notesChunkTokens: Int {
        max(1, settings.integer(Key.notesChunkTokens, default: Self.defaultNotesChunkTokens))
    }

    var notesReduceInputTokens: Int {
        max(1, settings.integer(Key.notesReduceInputTokens, default: Self.defaultNotesReduceInputTokens))
    }

    // MARK: Meeting suggestions

    var suggestMeetings: Bool { settings.bool(Key.suggestMeetings, default: false) }
    var suggestMutedBundleIDs: [String] { settings.stringArray(Key.suggestMutedBundleIDs) ?? [] }
    var suggestExtraBundleIDs: [String] { settings.stringArray(Key.suggestExtraBundleIDs) ?? [] }

    // MARK: Retention

    /// 0 means unlimited; a negative stored value counts as the default.
    var retentionDays: Int {
        let days = settings.integer(Key.retentionDays, default: Self.defaultRetentionDays)
        return days < 0 ? Self.defaultRetentionDays : days
    }

    var orphanAudioDays: Int { max(1, settings.integer(Key.orphanAudioDays, default: Self.defaultOrphanAudioDays)) }

    func setSpeechModelID(_ id: String) { settings.set(id, for: Key.speechModel) }
    func setSpeechLanguage(_ language: String) { settings.set(language, for: Key.speechLanguage) }

    func setSpeechModelFolder(_ url: URL?) {
        if let url {
            settings.set(url.path, for: Key.speechModelFolder)
        } else {
            settings.removeValue(for: Key.speechModelFolder)
        }
    }

    func setDiarizationModelFolder(_ url: URL?) {
        if let url {
            settings.set(url.path, for: Key.diarizationModelFolder)
        } else {
            settings.removeValue(for: Key.diarizationModelFolder)
        }
    }

    func setInputDevice(_ uid: String?) {
        if let uid { settings.set(uid, for: Key.inputDevice) } else { settings.removeValue(for: Key.inputDevice) }
    }

    func setVoiceProcessing(_ value: Bool) { settings.set(value, for: Key.voiceProcessing) }
    func setSystemAudio(_ value: Bool) { settings.set(value, for: Key.systemAudio) }
    func setDiarization(_ value: Bool) { settings.set(value, for: Key.diarization) }
    func setConsentReminder(_ value: Bool) { settings.set(value, for: Key.consentReminder) }
    func setNotesEnabled(_ value: Bool) { settings.set(value, for: Key.notesEnabled) }
    func setBuiltInLLMModel(_ model: LLMModel) { settings.set(model.id, for: Key.builtInLLMModel) }
    func setSuggestMeetings(_ value: Bool) { settings.set(value, for: Key.suggestMeetings) }
    func setSuggestMutedBundleIDs(_ ids: [String]) { settings.set(ids, for: Key.suggestMutedBundleIDs) }
    func setSuggestExtraBundleIDs(_ ids: [String]) { settings.set(ids, for: Key.suggestExtraBundleIDs) }
    func setRetentionDays(_ days: Int) { settings.set(max(0, days), for: Key.retentionDays) }
    func setOrphanAudioDays(_ days: Int) { settings.set(days, for: Key.orphanAudioDays) }
}
