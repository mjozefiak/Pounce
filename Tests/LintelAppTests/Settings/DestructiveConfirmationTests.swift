import Foundation
import LintelKit
import LintelUI
import Testing

@testable import LintelApp

/// Step 3.4: every Clear and Erase in the app shell asks first, with the verb on the confirm button.
@MainActor
@Suite struct DestructiveConfirmationTests {
    private static func entry(_ key: String) throws -> [String: Any] {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        return try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
    }

    static func expectTranslated(_ resource: LocalizedStringResource) throws {
        let item = try entry(resource.key)
        let localizations = try #require(item["localizations"] as? [String: Any])
        for language in ["en", "pl"] {
            #expect(localizations[language] != nil, "\(resource.key) lacks \(language)")
        }
    }

    @Test func eraseDataAndResetRankingHaveEnglishAndPolishCopy() throws {
        let manifest = PluginManifest(
            id: "apps", displayName: "Apps", symbolName: "app", order: 10)
        for confirmation in [FeatureRow.confirmation(for: manifest), AdvancedPane.confirmation] {
            for resource in [confirmation.prompt, confirmation.detail, confirmation.confirmTitle] {
                try Self.expectTranslated(resource)
            }
            #expect(confirmation.confirmTitle.key != "OK")
        }
        #expect(AdvancedPane.confirmation.confirmTitle.key == "Reset Ranking")
        #expect(FeatureRow.confirmation(for: manifest).confirmTitle.key == "Erase Data")
    }
}
