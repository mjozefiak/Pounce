import Foundation
import PounceKit

/// `plugins.dictation.*` (a protected contract from the release that ships it, `BACKWARD_COMPATIBILITY.md` §3).
/// Phase 1 reads the speech model, the microphone, keep-warm and the clipboard restore; the formatting and
/// history keys arrive with their phases.
struct DictationSettings: Sendable {
    enum Key {
        static let speechModel = "speechModel"
        static let speechLanguage = "speechLanguage"
        static let speechModelFolder = "speechModelFolder"
        static let inputDevice = "inputDevice"
        static let keepWarmMinutes = "keepWarmMinutes"
        static let restoreClipboard = "restoreClipboard"
        static let mode = "mode"
        static let llmEndpoint = "llmEndpoint"
        static let llmModel = "llmModel"
        static let historyEnabled = "historyEnabled"
        static let retentionDays = "retentionDays"
        static let maximumEntries = "maximumEntries"
    }

    static let defaultRetentionDays = 30
    static let defaultMaximumEntries = 500
    static let retentionDayChoices = [1, 7, 30, 90]
    static let maximumEntryChoices = [100, 250, 500, 1000]

    /// What happens to the transcript before it is pasted.
    enum Mode: String, Sendable, CaseIterable {
        /// The transcript as the speech model wrote it.
        case raw
        /// Cleaned up by the user's local language model ("Porządkuj").
        case cleanup
    }

    static let defaultSpeechModel = "parakeet-ultra"
    static let defaultKeepWarmMinutes = 10

    private let settings: PluginSettings

    init(_ settings: PluginSettings) {
        self.settings = settings
    }

    var speechModelID: String { settings.string(Key.speechModel) ?? Self.defaultSpeechModel }

    /// `pl` or `en`; only the Whisper engine uses it.
    var speechLanguage: String { settings.string(Key.speechLanguage) == "en" ? "en" : "pl" }

    /// A folder the user downloaded the model into by hand.
    var speechModelFolder: URL? {
        guard let path = settings.string(Key.speechModelFolder), !path.isEmpty else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// The input device's UID; `nil` follows the system's input.
    var inputDevice: String? {
        guard let uid = settings.string(Key.inputDevice), !uid.isEmpty else { return nil }
        return uid
    }

    var keepWarm: Duration {
        .seconds(60 * max(0, settings.integer(Key.keepWarmMinutes, default: Self.defaultKeepWarmMinutes)))
    }

    var restoresClipboard: Bool { settings.bool(Key.restoreClipboard, default: true) }

    var mode: Mode { settings.string(Key.mode).flatMap(Mode.init(rawValue:)) ?? .raw }

    /// The formatting server's address, always a loopback one (the setter refuses anything else).
    var llmEndpoint: URL? {
        settings.string(Key.llmEndpoint).flatMap { LoopbackPolicy.parse($0) }
    }

    var llmModel: String? {
        guard let model = settings.string(Key.llmModel), !model.isEmpty else { return nil }
        return model
    }

    /// The server and model to format with, or `nil` until both are chosen.
    var llmTarget: LocalLLMFormatter.Target? {
        guard let url = llmEndpoint, let model = llmModel else { return nil }
        return .init(baseURL: url, model: model)
    }

    /// Whether finished dictations are kept (encrypted) in the history.
    var historyEnabled: Bool { settings.bool(Key.historyEnabled, default: true) }
    var retentionDays: Int { max(1, settings.integer(Key.retentionDays, default: Self.defaultRetentionDays)) }
    var maximumEntries: Int { max(1, settings.integer(Key.maximumEntries, default: Self.defaultMaximumEntries)) }

    func setHistoryEnabled(_ value: Bool) { settings.set(value, for: Key.historyEnabled) }
    func setRetentionDays(_ days: Int) { settings.set(days, for: Key.retentionDays) }
    func setMaximumEntries(_ count: Int) { settings.set(count, for: Key.maximumEntries) }

    func setMode(_ mode: Mode) { settings.set(mode.rawValue, for: Key.mode) }
    func setLLMModel(_ model: String?) {
        if let model, !model.isEmpty {
            settings.set(model, for: Key.llmModel)
        } else {
            settings.removeValue(for: Key.llmModel)
        }
    }

    /// Returns false (and stores nothing) when the address is not on this Mac.
    @discardableResult
    func setLLMEndpoint(_ text: String) -> Bool {
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            settings.removeValue(for: Key.llmEndpoint)
            return true
        }
        guard let url = LoopbackPolicy.parse(text) else { return false }
        settings.set(url.absoluteString, for: Key.llmEndpoint)
        return true
    }

    func setSpeechModelFolder(_ url: URL?) {
        if let url {
            settings.set(url.path, for: Key.speechModelFolder)
        } else {
            settings.removeValue(for: Key.speechModelFolder)
        }
    }

    func setInputDevice(_ uid: String?) {
        if let uid { settings.set(uid, for: Key.inputDevice) } else { settings.removeValue(for: Key.inputDevice) }
    }

    func setKeepWarmMinutes(_ minutes: Int) { settings.set(minutes, for: Key.keepWarmMinutes) }
    func setRestoresClipboard(_ value: Bool) { settings.set(value, for: Key.restoreClipboard) }
    func setSpeechModelID(_ id: String) { settings.set(id, for: Key.speechModel) }
    func setSpeechLanguage(_ language: String) { settings.set(language, for: Key.speechLanguage) }
}
