import Foundation
import LintelUI
import Testing

@testable import DictationPlugin

/// Spec `2026-11-04-lintel-main-window`, step 5.3 (owner decision L1-39): Clear History says that copies edited
/// or commented on in Notes stay and offers "Also delete kept copies", off by default; in every build since Notes was
/// enabled (step 7.1).
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
        let confirmation = HistorySection.confirmationInMainWindow(keptCopies: 2)
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

    @Test func theCheckboxIsInEveryBuildAndThePaneHandsItsStateToTheAction() throws {
        let pane = try Self.source("DictationSettingsPane.swift")
        #expect(pane.contains("history.clear(alsoDeleteKeptCopies: alsoDeleteKeptCopies)"))
        // Notes is enabled (spec B step 7.1): the sentence is not behind `#if DEBUG` any more.
        #expect(pane.contains(".keptNotesCopies(count: keptCopies)"))
        #expect(!pane.contains("#if DEBUG"))
    }

    @Test func withoutKeptCopiesTheSheetHasNoCheckbox() {
        #expect(HistorySection.confirmationInMainWindow(keptCopies: 0).option == nil)
    }

    @Test func theCopiesAreDeletedOnlyWhenTheBoxIsTickedAndAfterTheHistoryWasCleared() async throws {
        let harness = try DictationHarness(keychain: MemoryKeychain())
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        try await plugin.activate()
        let history = plugin.history
        let model = HistorySettingsModel(settings: DictationSettings(harness.context.settings), history: history)
        var calls = 0
        model.deleteKeptCopies = {
            calls += 1
            return true
        }
        model.clear(alsoDeleteKeptCopies: false)
        #expect(calls == 0, "unticked: nothing in Notes is deleted")
        await model.clear(alsoDeleteKeptCopies: true)?.value
        #expect(calls == 1)
        await plugin.deactivate()
    }

    @Test func clearingWithTheFlagStillWorksOnAnEmptyHistory() async throws {
        let harness = try DictationHarness(keychain: MemoryKeychain())
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        try await plugin.activate()
        let model = HistorySettingsModel(settings: DictationSettings(harness.context.settings), history: plugin.history)
        await model.clear(alsoDeleteKeptCopies: true)?.value
        #expect(plugin.history.entryCount == 0)
        #expect(model.errorMessage == nil)
        await plugin.deactivate()
    }
}
