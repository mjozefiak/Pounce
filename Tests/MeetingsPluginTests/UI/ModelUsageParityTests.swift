import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 3.3: the pane's one-line summaries follow the models' state, and
/// every "in use" check the setup step's cards use is the one `modelUsage` gives the Models pane.
@MainActor
@Suite struct MeetingsModelUsageParityTests {
    @Test func theSummaryFollowsTheCard() throws {
        let rig = try SettingsRig()
        #expect(rig.model.speech.choiceState == .notInstalled)
        #expect(rig.model.diarization.choiceState == .notInstalled)
    }

    // MARK: "In use" parity

    @Test func theSpeechAndDiarizationCardsAndModelUsageAskTheSameCheck() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let cards = [plugin.ui.model.speech, plugin.ui.model.diarization]
        let usages = Array(plugin.modelUsage.prefix(2))
        #expect(usages.map(\.kind) == [.speech, .diarization])
        for active in [true, false] {
            if active { plugin.activity.begin() } else { plugin.activity.end() }
            for (card, usage) in zip(cards, usages) {
                await card.refresh()
                #expect(card.isInUse == active)
                #expect(await usage.isInUse() == active)
            }
        }
    }

    /// The notes model: today `NotesSettingsModel` refuses removal while `service.isBusy` or the shared lease holds
    /// the file; `modelUsage` must ask the same service and the same lease.
    @Test func theNotesModelUsesTheSameServiceAndLease() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let notesCard = Mirror(reflecting: plugin.ui.model.notes)
        let service = try #require(notesCard.descendant("service") as? NotesService)
        let lease = try #require(notesCard.descendant("lease") as? LLMLease)
        #expect(service === plugin.notes)
        #expect(lease === LLMLease.shared)

        let guards = try Self.read("Sources/MeetingsPlugin/Notes/NotesSettingsModel.swift")
        #expect(guards.contains("service.isBusy"))
        #expect(guards.contains("lease.isInUse(modelID:"))
        let usage = try Self.read("Sources/MeetingsPlugin/MeetingsPlugin+Models.swift")
        #expect(usage.contains("if notes.isBusy { return true }"))
        #expect(usage.contains("LLMLease.shared.isInUse(modelID: file.path)"))
        #expect(usage.contains("let notes = notes"))
    }

    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func read(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
