import Foundation
import LintelKit
import LintelSpeech
import LintelUI
import SwiftUI
import Testing

@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 3.3: the old Settings window (`.legacyWindow`, what release users
/// see) still draws both model cards and the microphone rows; the main window draws the one-line summaries with
/// their link to Models instead. And every "in use" check the cards use today is the one `modelUsage` gives the
/// Models pane.
@MainActor
@Suite struct MeetingsHostStyleParityTests {
    /// The view types a `body` value holds, found by reflection: the branch an `if` took is stored, the other is
    /// not. Outside a host `settingsHostStyle` keeps its default, `.legacyWindow`, as `SettingsWindowController`
    /// leaves it.
    private static func typeNames(in value: Any, depth: Int = 0) -> Set<String> {
        guard depth < 60 else { return [] }
        let type = String(describing: Swift.type(of: value))
        var names: Set<String> = [type.components(separatedBy: "<").first ?? type]
        for child in Mirror(reflecting: value).children {
            names.formUnion(typeNames(in: child.value, depth: depth + 1))
        }
        return names
    }

    @Test func theOldWindowKeepsTheModelCardsAndTheMicrophoneRows() throws {
        let rig = try SettingsRig()
        let types = Self.typeNames(
            in: LegacyMeetingsSettingsPane(model: rig.model, recorder: nil, isActive: false).body)
        #expect(types.contains("MeetingsModelCard"))
        #expect(types.contains("NotesSettingsRows"))
        #expect(types.contains("MeetingsMicrophoneRows"))
        #expect(types.contains("MeetingsInputDevicePicker"))
        #expect(!types.contains("ModelChoiceRow"))
    }

    @Test func bothHostsRender() throws {
        let rig = try SettingsRig()
        for style in [SettingsHostStyle.legacyWindow, .mainWindow] {
            let pane = MeetingsSettingsPane(model: rig.model, recorder: nil, isActive: false)
                .environment(\.settingsHostStyle, style)
                .frame(width: 600, height: 900)
            #expect(ImageRenderer(content: pane).nsImage != nil)
        }
    }

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
