import Foundation
import Testing

/// Spec `2026-11-04-lintel-main-window`, step 2.4 (risk R-A4): every key of the Meetings plugin's settings type is
/// either used by its settings pane (the token is a setter or control the pane sources must contain) or listed
/// in `exempt` with the reason it has no control. A new key fails `everyKeyIsReachableOrExempt` until it is
/// added to one of the two tables.
@Suite struct SettingsKeyCoverageTests {
    /// Key constant name to a token that must appear in the pane sources.
    static let paneTokens: [String: String] = [
        "speechModel": "setSpeechModelID",
        "speechLanguage": "setSpeechLanguage",
        "speechModelFolder": "setSpeechModelFolder",
        "diarizationModelFolder": "setDiarizationModelFolder",
        "inputDevice": "setInputDevice",
        "voiceProcessing": "setVoiceProcessing",
        "consentReminder": "setConsentReminder",
        "notesEnabled": "setNotesEnabled",
        "builtInLLMModel": "setBuiltInLLMModel",
        "suggestMeetings": "setSuggestMeetings",
        "suggestMutedBundleIDs": "setSuggestMutedBundleIDs",
        "suggestExtraBundleIDs": "setSuggestExtraBundleIDs",
        "retentionDays": "setRetentionDays",
    ]

    /// Keys with no pane control, each with the reason. The prototype figure `set-meetings` shows no control for
    /// any of them either (step 5.2).
    static let exempt: [String: String] = [
        "systemAudio": "no pane control by design: capture setting kept for defaults, default on",
        "diarization": "no pane control by design: capture setting kept for defaults, default on",
        "notesChunkTokens": "tuning key set with defaults only; no pane control by design",
        "notesReduceInputTokens": "tuning key set with defaults only; no pane control by design",
        "orphanAudioDays": "tuning key set with defaults only; no pane control by design",
    ]

    /// The pane view and model sources, relative to the repository root.
    static let paneFiles = [
        "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift",
        "Sources/MeetingsPlugin/UI/MeetingsViews.swift",
        "Sources/MeetingsPlugin/UI/MeetingsSettingsModel.swift",
        "Sources/MeetingsPlugin/Suggestions/MeetingsSettingsModel+Suggestions.swift",
        "Sources/MeetingsPlugin/Notes/NotesViews.swift",
        "Sources/MeetingsPlugin/Notes/NotesSettingsModel.swift",
        "Sources/MeetingsPlugin/MeetingsPlugin+Settings.swift",
    ]

    /// Step 5.2: the view token of every non-exempt key in the main window's sources, so a key stays
    /// reachable there. The setters above live in the shared models; these are the controls that call them.
    static let windowTokens: [(window: String, files: [String], tokens: [String: String])] = [
        (
            "main window",
            [
                "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift",
                // Both model folders are chosen in the Models pane through the usages' `chooseFolder`.
                "Sources/MeetingsPlugin/MeetingsPlugin+Models.swift",
            ],
            [
                "speechModel": "model.selectSpeechModel(",
                "speechLanguage": "$model.speechLanguage",
                "speechModelFolder": "chooseFolder: { settings.setSpeechModelFolder($0) }",
                "diarizationModelFolder": "chooseFolder: { settings.setDiarizationModelFolder($0) }",
                "inputDevice": "$model.inputDevice",
                "voiceProcessing": "$model.voiceProcessing",
                "consentReminder": "$model.consentReminder",
                "notesEnabled": "model.notes.enabled = ",
                "builtInLLMModel": "notes.choose(",
                "suggestMeetings": "$model.suggestMeetings",
                "suggestMutedBundleIDs": "model.unmute(",
                "suggestExtraBundleIDs": "model.addExtraApp(",
                "retentionDays": "model.selectRetention(",
            ]
        )
    ]

    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    /// The constant names declared inside the key enum of the settings source.
    private static func declaredKeys() throws -> [String] {
        let source = try read("Sources/MeetingsPlugin/MeetingsSettings.swift")
        guard let header = source.range(of: "enum Key {") else { return [] }
        let rest = source[header.upperBound...]
        let body = rest[..<(rest.range(of: "\n    }")?.lowerBound ?? rest.endIndex)]
        return body.matches(of: #/static let (\w+) = "/#).map { String($0.1) }
    }

    @Test func everyKeyIsReachableOrExempt() throws {
        let declared = try Self.declaredKeys()
        #expect(!declared.isEmpty, "the key enum was not found in the settings source")
        for key in declared {
            let inPane = Self.paneTokens[key] != nil
            let isExempt = Self.exempt[key] != nil
            #expect(inPane != isExempt, "\(key) must be in exactly one of paneTokens and exempt")
        }
        let known = Set(Self.paneTokens.keys).union(Self.exempt.keys)
        #expect(known == Set(declared), "a table row names a key that no longer exists: \(known.subtracting(declared))")
    }

    @Test func paneSourcesReferenceEveryNonExemptKey() throws {
        let panes = try Self.paneFiles.map { try Self.read($0) }.joined(separator: "\n")
        for (key, token) in Self.paneTokens {
            #expect(panes.contains(token), "\(key): the pane sources do not contain \(token)")
        }
        for (key, reason) in Self.exempt {
            #expect(!reason.isEmpty, "\(key) needs a reason")
        }
    }

    @Test func theWindowReachesEveryNonExemptKey() throws {
        for window in Self.windowTokens {
            #expect(Set(window.tokens.keys) == Set(Self.paneTokens.keys), "\(window.window): the key list differs")
            let source = try window.files.map { try Self.read($0) }.joined(separator: "\n")
            for (key, token) in window.tokens {
                #expect(source.contains(token), "\(key): the \(window.window) sources do not contain \(token)")
            }
        }
    }
}
