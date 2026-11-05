import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 3.2: the models Meetings declares for the shell's Models pane.
@MainActor
@Suite struct MeetingsModelUsageTests {
    @Test func declaresSpeechDiarizationAndTheNotesModel() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let usages = plugin.modelUsage
        #expect(usages.map(\.kind) == [.speech, .diarization, .llm])
        let speech = usages[0]
        #expect(speech.packageID == ModelCatalog.parakeetUltra.id)
        #expect(speech.isRequired && speech.isSelected)
        #expect(speech.chooseFolder != nil)
        let diarization = usages[1]
        #expect(diarization.packageID == ModelCatalog.diarizationCommunity1.id)
        #expect(!diarization.isRequired)
        // `diarization` is on by default.
        #expect(diarization.isSelected)
        #expect(diarization.chooseFolder != nil)
        let notes = usages[2]
        #expect(notes.packageID == LLMModelCatalog.defaultModel.id || LLMModelCatalog.model(id: notes.packageID) != nil)
        #expect(!notes.isRequired)
        // Notes are off by default.
        #expect(!notes.isSelected)
        #expect(notes.chooseFolder == nil)
    }

    @Test func selectionFollowsTheSettings() throws {
        let harness = try MeetingsHarness(settings: [
            "plugins.meetings.diarization": .bool(false), "plugins.meetings.notesEnabled": .bool(true),
            "plugins.meetings.speechModel": .string(ModelCatalog.whisperLargeV3Turbo.id),
        ])
        let plugin = MeetingsPlugin(context: harness.context)
        let usages = plugin.modelUsage
        #expect(usages[0].packageID == ModelCatalog.whisperLargeV3Turbo.id)
        #expect(!usages[1].isSelected)
        #expect(usages[2].isSelected)
    }

    @Test func chooseFolderWritesThePluginsOwnFolderKeys() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let folder = harness.directory.url.appending(path: "hand", directoryHint: .isDirectory)
        plugin.modelUsage[0].chooseFolder?(folder)
        plugin.modelUsage[1].chooseFolder?(folder)
        #expect(plugin.settings.speechModelFolder?.path == folder.path)
        #expect(plugin.settings.diarizationModelFolder?.path == folder.path)
    }

    @Test func aChosenSpeechFolderIsNotRequired() throws {
        let harness = try MeetingsHarness(settings: [
            "plugins.meetings.speechModelFolder": .string(FileManager.default.temporaryDirectory.path)
        ])
        let plugin = MeetingsPlugin(context: harness.context)
        // The Models pane does not see the chosen folder, so the model must not count as missing.
        #expect(!plugin.modelUsage[0].isRequired)
        #expect(plugin.modelUsage[0].isSelected)
    }

    @Test func anActiveMeetingHoldsTheSpeechAndTheDiarizationModel() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        plugin.activity.begin()
        defer { plugin.activity.end() }
        #expect(await plugin.modelUsage[0].isInUse())
        #expect(await plugin.modelUsage[1].isInUse())
    }

    @Test func theNotesModelIsFreeWhileNoNotesRun() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        // Not installed and no job queued: nothing holds it.
        #expect(await plugin.modelUsage[2].isInUse() == false)
    }

    @Test func aRemovalReservationBlocksStartingARecording() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let hud = RecordingHUD()
        plugin.adjustControllerDependencies = { dependencies in
            dependencies.authorizer = FakeAuthorizer(.granted)
            dependencies.hud = hud
            dependencies.speechModel = { .ready(modelID: "parakeet-ultra", folder: URL(filePath: "/tmp/lintel-model")) }
            dependencies.makeSession = { _ in ScriptedSession(ScriptedSession.Behaviour()) }
        }
        try await plugin.activate()
        let controller = try #require(plugin.controller)
        // The Models pane holds every speech usage's reservation while it removes a model.
        let release = plugin.modelUsage[0].reserveRemoval()
        #expect(plugin.activity.isRemovingModel)
        controller.start()
        #expect(hud.last == .problem(.modelBeingRemoved))
        #expect(controller.phase == .idle)
        release()
        #expect(!plugin.activity.isRemovingModel)
        await plugin.deactivate()
    }
}
