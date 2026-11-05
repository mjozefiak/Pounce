import Foundation
import Testing

@testable import LintelApp

/// Step 6.5i: a catalog key that release screens still draw keeps its release wording (ADR 0008 Release gate);
/// the main window has its own keys with the new wording. Release values are pinned here because a test cannot
/// read `origin/main`.
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

    @Test func releaseKeysKeepTheirReleaseText() throws {
        let strings = try strings()
        let release: [(String, String, String)] = [
            ("Choose Folder…", "en", "Choose Folder…"), ("Choose Folder…", "pl", "Wskaż folder…"),
            ("Not downloaded", "en", "Not downloaded"), ("Not downloaded", "pl", "Nie pobrano"),
            (
                "All entries are deleted. This cannot be undone.", "en",
                "All entries are deleted. This cannot be undone."
            ),
            (
                "Results go back to the order of how well they match. It cannot be undone.", "en",
                "Results go back to the order of how well they match. It cannot be undone."
            ),
            (
                "This deletes every saved dictation. It cannot be undone.", "en",
                "This deletes every saved dictation. It cannot be undone."
            ),
            (
                "This deletes everything the feature stored on this Mac. It cannot be undone.", "en",
                "This deletes everything the feature stored on this Mac. It cannot be undone."
            ),
            (
                "Suggestions start again from the apps you use next. This cannot be undone.", "en",
                "Suggestions start again from the apps you use next. This cannot be undone."
            ),
            (
                "The transcript, notes and any saved audio are removed from this Mac. This cannot be undone.", "en",
                "The transcript, notes and any saved audio are removed from this Mac. This cannot be undone."
            ),
            (
                "Every transcript, note and recording is deleted. A meeting that is being recorded is kept. This cannot be undone.",
                "en",
                "Every transcript, note and recording is deleted. A meeting that is being recorded is kept. This cannot be undone."
            ),
        ]
        for (key, language, expected) in release {
            #expect(value(strings, key, language) == expected, "\(key) [\(language)]")
        }
        #expect(value(strings, "This deletes every saved dictation. It cannot be undone.", "pl") != nil)
        #expect(
            strings["%lld meetings are older than the new limit and are deleted now. This cannot be undone."] != nil)
    }

    @Test func theMainWindowHasItsOwnKeysWithTheNewText() throws {
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

    @Test func theOldWindowGetsDetailAndTheMainWindowItsOwnDetail() {
        let confirmation = AdvancedPane.confirmation
        #expect(confirmation.detail.key == "Results go back to the order of how well they match. It cannot be undone.")
        #expect(
            confirmation.mainWindowDetail?.key
                == "Results go back to the order of how well they match. This can’t be undone.")
    }
}
