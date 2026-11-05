import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Step 6.5i: a catalog key that the welcome screen's setup steps and the meeting window still draw keeps its
/// release wording; the Models pane has its own keys with the new wording. Step 6.3b: the old window's dialog
/// texts are gone and every Settings confirmation says "This can’t be undone." Release values are pinned here
/// because a test cannot read `origin/main`.
struct ReleaseStringParityTests {
    private func strings() throws -> [String: [String: Any]] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try #require(root["strings"] as? [String: [String: Any]])
    }

    private func value(_ strings: [String: [String: Any]], _ key: String, _ language: String) -> String? {
        let locs = strings[key]?["localizations"] as? [String: [String: [String: String]]]
        return locs?[language]?["stringUnit"]?["value"]
    }

    @Test func sharedKeysKeepTheirReleaseText() throws {
        let strings = try strings()
        let release: [(String, String, String)] = [
            ("Choose Folder…", "en", "Choose Folder…"), ("Choose Folder…", "pl", "Wskaż folder…"),
            ("Not downloaded", "en", "Not downloaded"), ("Not downloaded", "pl", "Nie pobrano"),
            (
                "The transcript, notes and any saved audio are removed from this Mac. This cannot be undone.", "en",
                "The transcript, notes and any saved audio are removed from this Mac. This cannot be undone."
            ),
        ]
        for (key, language, expected) in release {
            #expect(value(strings, key, language) == expected, "\(key) [\(language)]")
        }
    }

    /// The old window's dialog texts, removed with it (step 6.3b).
    @Test func theOldDialogTextsAreGone() throws {
        let strings = try strings()
        for key in [
            "All entries are deleted. This cannot be undone.",
            "Results go back to the order of how well they match. It cannot be undone.",
            "This deletes every saved dictation. It cannot be undone.",
            "This deletes everything the feature stored on this Mac. It cannot be undone.",
            "Suggestions start again from the apps you use next. This cannot be undone.",
            "Every transcript, note and recording is deleted. A meeting that is being recorded is kept. This cannot be undone.",
            "%lld meetings are older than the new limit and are deleted now. This cannot be undone.",
        ] {
            #expect(strings[key] == nil, "\(key)")
        }
    }

    @Test func theSettingsHaveTheirOwnKeysWithTheNewText() throws {
        let strings = try strings()
        #expect(value(strings, "Choose Folder… (models)", "en") == "Choose Folder…")
        #expect(value(strings, "Choose Folder… (models)", "pl") == "Wybierz folder…")
        #expect(value(strings, "Not downloaded (models)", "en") == "Not downloaded")
        #expect(value(strings, "Not downloaded (models)", "pl") == "Niepobrany")
        for key in [
            "All entries are deleted. This can’t be undone.",
            "Results go back to the order of how well they match. This can’t be undone.",
            "This deletes every saved dictation. This can’t be undone.",
            "This deletes everything the feature stored on this Mac. This can’t be undone.",
            "Every transcript, note and recording is deleted. A meeting that is being recorded is kept. This can’t be undone.",
            "%lld meetings are older than the new limit and are deleted now. This can’t be undone.",
            "Lintel forgets which apps you used. This can’t be undone.",
        ] {
            #expect(strings[key] != nil, "\(key)")
        }
    }

    @Test func theConfirmationsUseTheNewText() {
        #expect(
            AdvancedPane.confirmation.detail.key
                == "Results go back to the order of how well they match. This can’t be undone.")
        let manifest = PluginManifest(id: "apps", displayName: "Apps", symbolName: "app", order: 10)
        #expect(
            FeatureEraseRow.eraseConfirmation(for: manifest).detail.key
                == "This deletes everything the feature stored on this Mac. This can’t be undone.")
    }
}
