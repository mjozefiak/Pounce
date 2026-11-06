import Foundation
import Testing

@testable import DictationPlugin

/// Step 3.4: Clear History asks before it deletes, with a verb on the confirm button, in English and Polish.
@Suite struct DictationClearConfirmationTests {
    private func expectTranslated(_ key: String) throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(localizations["en"] != nil && localizations["pl"] != nil, "\(key) needs en and pl")
    }

    @Test func theConfirmationHasWordsAndAVerb() throws {
        for resource in [
            HistorySection.confirmation.prompt, HistorySection.confirmation.detail,
            HistorySection.confirmation.confirmTitle,
        ] { try expectTranslated(resource.key) }
        #expect(HistorySection.confirmation.confirmTitle.key == "Clear History")
    }
}
