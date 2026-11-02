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
