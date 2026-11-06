import Foundation
import Testing

/// Spec step 6.2: every string of the lock strip, the reports and "Ask agent" has English and Polish, and the
/// counts have the Polish plural forms (one, few, many, other). The catalog is read from the repository.
@Suite struct NotesAgentCopyTests {
    private nonisolated(unsafe) static let catalog: [String: Any] = {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = json["strings"] as? [String: Any]
        else { return [:] }
        return strings
    }()

    private func localization(_ key: String, _ language: String) -> [String: Any]? {
        ((Self.catalog[key] as? [String: Any])?["localizations"] as? [String: Any])?[language] as? [String: Any]
    }

    private func value(_ key: String, _ language: String) -> String? {
        (localization(key, language)?["stringUnit"] as? [String: Any])?["value"] as? String
    }

    private func plural(_ key: String, _ language: String) -> [String: String]? {
        let forms = ((localization(key, language)?["variations"] as? [String: Any])?["plural"] as? [String: Any])
        return forms?.compactMapValues {
            (($0 as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
    }

    private let simple = [
        "Waiting for the model", "Agent is writing notes · read-only until it finishes",
        "The agent’s answer couldn’t be used. Nothing was changed.",
        "The note changed while the agent was working. Nothing was changed.",
        "The agent took too long. Nothing was changed.", "The agent couldn’t finish. Nothing was changed.",
        "The notes model is being removed. Try again in a moment.", "Queued", "Ask agent",
        "The agent revises only the commented blocks.", "Revised", "Cancel", "Try again", "Open Models",
    ]

    private let counted = [
        "Revised %lld blocks from comments. Restore is in History.",
        "%lld blocks couldn’t be revised and were left as they are.",
        "You edited %lld blocks, so they were not changed.",
        "The text of %lld comments is gone, so they were not revised.",
        "%lld comments are too much for one run and stay open.", "Revised %lld blocks from comments",
    ]

    @Test func everyPlainStringHasEnglishAndPolish() {
        for key in simple {
            #expect(value(key, "en")?.isEmpty == false, "\(key) en")
            #expect(value(key, "pl")?.isEmpty == false, "\(key) pl")
        }
    }

    @Test func everyCountedStringHasTheFourPolishFormsAndTwoEnglishOnes() {
        for key in counted {
            #expect(Set(plural(key, "en").map { Array($0.keys) } ?? []) == ["one", "other"], "\(key) en")
            #expect(
                Set(plural(key, "pl").map { Array($0.keys) } ?? []) == ["one", "few", "many", "other"], "\(key) pl")
            for form in (plural(key, "pl") ?? [:]).values { #expect(!form.isEmpty) }
        }
    }

    @Test func oneBlockSaysThisBlockLikeTheSpec() {
        #expect(
            plural("You edited %lld blocks, so they were not changed.", "en")?["one"]
                == "You edited this block, so it was not changed.")
        #expect(
            plural("You edited %lld blocks, so they were not changed.", "pl")?["one"]
                == "Ten blok został przez Ciebie zmieniony, więc go nie poprawiono.")
    }

    @Test func thePolishTextNeverInflectsTheProductName() {
        for key in simple + counted {
            let forms = [value(key, "pl")].compactMap { $0 } + Array((plural(key, "pl") ?? [:]).values)
            for form in forms { #expect(!form.contains("Lintel")) }
        }
    }
}
