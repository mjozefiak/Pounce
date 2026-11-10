import Foundation
import Testing

@testable import LintelApp

/// Step 6.5f: the main window's Polish copy follows the prototype, while the keys other screens share (the
/// status menu, the welcome screen, the meeting window) keep their release wording.
struct PolishCopyTests {
    private func catalog() throws -> StringCatalogTests.Catalog {
        let data = try Data(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/Localizable.xcstrings"))
        return try JSONDecoder().decode(StringCatalogTests.Catalog.self, from: data)
    }

    private func value(_ key: String, _ language: String, in catalog: StringCatalogTests.Catalog) -> String? {
        catalog.strings[key]?.localizations?[language]?.stringUnit?.value
    }

    @Test func theMainWindowKeysHaveThePrototypeText() throws {
        let catalog = try catalog()
        let expected: [String: String] = [
            "settings.sidebar.search": "Szukanie",
            "settings.sidebar.off": "Wył.",
            "settings.sidebar.off.spoken": "Wyłączone",
            "Record meeting (settings)": "Nagraj spotkanie",
            "Suggest recording (settings)": "Proponuj nagranie, gdy zaczyna się spotkanie",
            "Test System Audio (settings)": "Przetestuj dźwięk systemu",
            "At most (dictation)": "Maksymalnie",
            "Not asked yet": "Jeszcze nie pytano",
            // Owner decision 6.6b: the Features descriptions.
            "Find and open apps.": "Szukaj i otwieraj aplikacje.",
            "Find files by name.": "Szukaj plików po nazwie.",
            "Paste from history.": "Wklejaj z historii.",
            "Speak instead of typing.": "Mów zamiast pisać.",
            "Record meetings, keep notes.": "Nagrywaj spotkania, miej notatki.",
            // Step 7.2: the welcome screen's final page says where the notes are. The prototype's "w oknie Lintel"
            // keeps the noun before the name (owner decision 6.6e).
            "Your notes live in the Lintel window: click the Dock icon or press ⌘,.":
                "Notatki są w oknie aplikacji Lintel: kliknij ikonę w Docku albo naciśnij ⌘,.",
            "Open Lintel with %@. Your notes live in the Lintel window: click the Dock icon or press ⌘,.":
                "Otwórz Lintel skrótem %@. Notatki są w oknie aplikacji Lintel: kliknij ikonę w Docku albo naciśnij ⌘,.",
            "Open Notes": "Otwórz Notatki",
        ]
        for (key, polish) in expected {
            #expect(value(key, "pl", in: catalog) == polish, "\(key)")
            #expect(value(key, "en", in: catalog)?.isEmpty == false, "\(key)")
        }
    }

    /// Owner decision 6.6e: the Polish copy never declines "Lintel". The name stays in the nominative and a
    /// case the sentence needs goes on a noun before it ("w aplikacji Lintel", "O aplikacji Lintel").
    @Test func thePolishCopyNeverDeclinesTheAppName() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // An ending glued to the name: Lintelu, Lintela, Lintelem, Lintelowi, Lintel’a, Lintel-a…
        let inflected = /Lintel(?:[\p{Ll}]|['’\-]\p{Ll})/
        // The bare name where Polish needs another case: "w Lintel", "O Lintel", "Zezwól Lintel"…
        let bareInOtherCase =
            /(?i:\b(?:o|w|we|z|ze|dla|do|od|przy|pozwala|pozwól|zezwól|uruchomić|uruchomienia|oknie|okna|schowka|samego)\s+Lintel\b)/
        for file in ["Resources/Localizable.xcstrings", "Resources/InfoPlist.xcstrings"] {
            let data = try Data(contentsOf: root.appending(path: file))
            let catalog = try JSONDecoder().decode(StringCatalogTests.Catalog.self, from: data)
            for (key, entry) in catalog.strings {
                for unit in entry.localizations?["pl"]?.units ?? [] {
                    guard let value = unit?.value else { continue }
                    #expect(value.firstMatch(of: inflected) == nil, "\(file): \(key) → \(value)")
                    #expect(value.firstMatch(of: bareInOtherCase) == nil, "\(file): \(key) → \(value)")
                }
            }
        }
    }

    @Test func theRephrasedKeysUseTheNominative() throws {
        let catalog = try catalog()
        let expected: [String: String] = [
            "About Lintel": "O aplikacji Lintel",
            "Welcome to Lintel": "Witaj w aplikacji Lintel",
            "Lintel cannot start": "Nie można uruchomić aplikacji Lintel",
            "macOS asks before every read. Allow Lintel in Privacy & Security.":
                "macOS pyta przed każdym odczytem. Zezwól aplikacji Lintel w sekcji Prywatność i ochrona.",
        ]
        for (key, polish) in expected {
            #expect(value(key, "pl", in: catalog) == polish, "\(key)")
        }
    }

    @Test func theSharedKeysAreUnchanged() throws {
        let catalog = try catalog()
        let shared: [String: String] = [
            "Search": "Szukaj",
            "Suggest recording when a meeting starts": "Podpowiadaj nagrywanie, gdy zaczyna się spotkanie",
            "Test System Audio": "Test dźwięku systemowego",
        ]
        for (key, polish) in shared {
            #expect(value(key, "pl", in: catalog) == polish, "\(key)")
        }
    }
}
