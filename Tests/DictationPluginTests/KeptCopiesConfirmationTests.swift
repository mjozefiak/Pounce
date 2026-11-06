import Foundation
import LintelUI
import Testing

@testable import DictationPlugin

/// Spec `2026-11-04-lintel-main-window`, step 5.3 (owner decision L1-39): Clear History says that copies edited
/// or commented on in Notes stay and offers "Also delete kept copies", off by default; in DEBUG only until Notes
/// ships.
@MainActor
@Suite struct DictationKeptCopiesConfirmationTests {
    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: root.appending(path: "Sources/DictationPlugin/\(name)"), encoding: .utf8)
    }

    @Test func clearHistoryHasTheNotesSentenceAndAnUncheckedBox() throws {
        let confirmation = HistorySection.confirmationInMainWindow
        let option = try #require(confirmation.option)
        #expect(option.title.key == "Also delete kept copies")
        #expect(option.explanation?.key.contains("Notes") == true)
        #expect(option.isOnByDefault == false)
        #expect(confirmation.confirmTitle.key == "Clear History")
    }

    @Test func onlyThePaneAddsTheCheckbox() throws {
        #expect(HistorySection.confirmation.option == nil)
        let views = try Self.source("DictationViews.swift")
        #expect(!views.contains("keptNotesCopies") && !views.contains("confirmationInMainWindow"))
    }

    @Test func theCheckboxIsGuardedAndThePaneHandsItsStateToTheAction() throws {
        let pane = try Self.source("DictationSettingsPane.swift")
        #expect(pane.contains("history.clear(alsoDeleteKeptCopies: alsoDeleteKeptCopies)"))
        let guarded = try #require(pane.range(of: "#if DEBUG\n        confirmation.with(option: .keptNotesCopies)"))
        let release = try #require(pane.range(of: "#else\n        confirmation\n        #endif"))
        #expect(guarded.upperBound <= release.lowerBound)
    }

    @Test func clearingWithTheFlagStillWorksOnAnEmptyHistory() async throws {
        let harness = try DictationHarness(keychain: MemoryKeychain())
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        try await plugin.activate()
        let model = HistorySettingsModel(settings: DictationSettings(harness.context.settings), history: plugin.history)
        model.clear(alsoDeleteKeptCopies: true)
        #expect(plugin.history.entryCount == 0)
        #expect(model.errorMessage == nil)
        await plugin.deactivate()
    }
}
