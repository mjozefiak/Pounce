import Foundation
import Testing

@testable import LintelApp

/// Step 6.5f: the main window's Polish copy follows the prototype, while the keys the old Settings window still
/// shows keep their release wording.
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
        ]
        for (key, polish) in expected {
            #expect(value(key, "pl", in: catalog) == polish, "\(key)")
            #expect(value(key, "en", in: catalog)?.isEmpty == false, "\(key)")
        }
    }

    @Test func theKeysOfTheOldWindowAreUnchanged() throws {
        let catalog = try catalog()
        let legacy: [String: String] = [
            "Search": "Szukaj",
            "Off": "Wyłączona",
            "Record meeting": "Nagrywaj spotkanie",
            "Suggest recording when a meeting starts": "Podpowiadaj nagrywanie, gdy zaczyna się spotkanie",
            "Test System Audio": "Test dźwięku systemowego",
            "At most": "Najwyżej",
        ]
        for (key, polish) in legacy {
            #expect(value(key, "pl", in: catalog) == polish, "\(key)")
        }
    }
}
