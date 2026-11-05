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

/// Step 5.3 (owner decision L1-39): Erase Data of Meetings and Dictation in Features → Advanced says that copies
/// edited or commented on in Notes stay and offers "Also delete kept copies", off by default; other features,
/// the old window and release builds keep today's words.
@MainActor
@Suite struct EraseDataKeptCopiesTests {
    private static func manifest(_ id: PluginID) -> PluginManifest {
        PluginManifest(id: id, displayName: "Feature", symbolName: "app", order: 10)
    }

    @Test func meetingsAndDictationOfferTheUncheckedBox() throws {
        for id: PluginID in ["meetings", "dictation"] {
            let confirmation = FeatureEraseRow.confirmation(for: Self.manifest(id))
            let option = try #require(confirmation.option(in: .mainWindow))
            #expect(option.isOnByDefault == false)
            #expect(option.title.key == "Also delete kept copies")
            try DestructiveConfirmationTests.expectTranslated(option.title)
            try DestructiveConfirmationTests.expectTranslated(try #require(option.explanation))
            #expect(confirmation.confirmTitle.key == "Erase Data")
            #expect(confirmation.option(in: .legacyWindow) == nil)
        }
    }

    @Test func otherFeaturesAndTheOldWindowHaveNoCheckbox() {
        for id: PluginID in ["apps", "files", "clipboard"] {
            #expect(FeatureEraseRow.confirmation(for: Self.manifest(id)).option == nil)
        }
        #expect(FeatureRow.confirmation(for: Self.manifest("meetings")).option == nil)
    }

    @Test func theCheckboxIsGuardedAndReachesTheEraseAction() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let pane = try String(
            contentsOf: url.appending(path: "Sources/LintelApp/Settings/FeaturesPane.swift"), encoding: .utf8)
        let legacy = try String(
            contentsOf: url.appending(path: "Sources/LintelApp/Settings/LegacyShellPanes.swift"), encoding: .utf8)
        #expect(pane.contains("entry.manifest.id, alsoDeleteKeptCopies: alsoDeleteKeptCopies"))
        let guarded = try #require(pane.range(of: "#if DEBUG\n        guard featuresWithNotesCopies"))
        let release = try #require(pane.range(of: "#else\n        return confirmation\n        #endif"))
        #expect(guarded.upperBound <= release.lowerBound)
        #expect(!legacy.contains("keptNotesCopies"))
    }
}
