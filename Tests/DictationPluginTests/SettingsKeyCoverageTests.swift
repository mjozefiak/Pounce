import Foundation
import Testing

/// Spec `2026-11-04-lintel-main-window`, step 2.4 (risk R-A4): every key of the Dictation plugin's settings type is
/// either used by its settings pane (the token is a setter or control the pane sources must contain) or listed
/// in `exempt` with the reason it has no control. A new key fails `everyKeyIsReachableOrExempt` until it is
/// added to one of the two tables.
@Suite struct SettingsKeyCoverageTests {
    /// Key constant name to a token that must appear in the pane sources.
    static let paneTokens: [String: String] = [
        "speechModel": "setSpeechModelID",
        "speechLanguage": "setSpeechLanguage",
        "speechModelFolder": "setSpeechModelFolder",
        "inputDevice": "setInputDevice",
        "restoreClipboard": "setRestoresClipboard",
        "mode": "setMode",
        "llmEndpoint": "setLLMEndpoint",
        "llmModel": "setLLMModel",
        "llmSource": "setLLMSource",
        "builtInLLMModel": "setBuiltInLLMModel",
        "historyEnabled": "setHistoryEnabled",
        "retentionDays": "setRetentionDays",
        "maximumEntries": "setMaximumEntries",
    ]

    /// Keys with no pane control, each with the reason.
    static let exempt: [String: String] = [
        "keepWarmMinutes":
            "tuning key set with defaults only; no pane control by design (BACKWARD_COMPATIBILITY section 3)"
    ]

    /// The pane view and model sources, relative to the repository root.
    static let paneFiles = [
        "Sources/DictationPlugin/DictationViews.swift",
        "Sources/DictationPlugin/DictationSettingsModel.swift",
        "Sources/DictationPlugin/FormattingSettingsModel.swift",
        "Sources/DictationPlugin/HistorySettingsModel.swift",
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
        let source = try read("Sources/DictationPlugin/DictationSettings.swift")
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
}
