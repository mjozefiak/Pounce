import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import NotesPlugin

/// Spec step 6.2 and main-window spec A 3.3: the Models pane's "in use" check of the notes model is
/// `runActive || lease.isInUse(modelID: path)`, with the same lease and the same path Meetings asks, and a removal
/// reserves the model so no run starts while the file goes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesModelUsageParityTests {
    @Test func theRowIsTheOptionalNotesModel() throws {
        let plugin = NotesPlugin(context: makeContext())
        let usage = try #require(plugin.modelUsage.first)
        #expect(plugin.modelUsage.count == 1)
        #expect(usage.kind == .llm)
        #expect(!usage.isRequired)
        #expect(usage.isSelected)
        #expect(LLMModelCatalog.model(id: usage.packageID) != nil)
    }

    @Test func inUseWhenARunIsActiveOrTheLeaseHoldsTheFile() async throws {
        let gate = ReviseGate()
        let handle = ScriptedReviseHandle([
            .after(gate, ReviseRig.unit("- Pricing page moves to the next sprint (owner: Marek).")), .hang,
        ])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")

        for (lease, expected) in [(false, false), (true, true)] {
            let check = NotesModelInUse(service: rig.service) { lease }
            #expect(await check() == expected)
        }
        let task = Task { await rig.service.start(rig.request()) }
        await handle.generating.wait()
        // A run is going on: in use even though the lease reports nothing.
        #expect(await NotesModelInUse(service: rig.service) { false }() == true)
        gate.open()
        _ = await task.value
        #expect(await NotesModelInUse(service: rig.service) { false }() == false)
    }

    @Test func aRemovalReservationStopsANewRunUntilItIsReleased() async throws {
        let rig = try ReviseRig(steps: [])
        let plugin = NotesPlugin(context: makeContext())
        let usage = try #require(plugin.modelUsage.first)
        let release = usage.reserveRemoval()
        #expect(await plugin.reviseService.start(rig.request()) == .modelBeingRemoved)
        release()
        #expect(await plugin.reviseService.start(rig.request()) != .modelBeingRemoved)
    }

    @Test func theUsageAsksTheSameServiceAndTheSameLeaseAsMeetingsDoes() throws {
        let notes = try Self.read("Sources/NotesPlugin/Agent/NotesPlugin+Revise.swift")
        #expect(notes.contains("service.isRunActive"))
        #expect(notes.contains("LLMLease.shared.isInUse(modelID: file.path)"))
        #expect(notes.contains("reserveRemoval: { service.reserveRemoval() }"))
        #expect(notes.contains("let service = reviseService"))
        let meetings = try Self.read("Sources/MeetingsPlugin/MeetingsPlugin+Models.swift")
        #expect(meetings.contains("LLMLease.shared.isInUse(modelID: file.path)"))
        // Leases and keys use the file path, not the catalog id.
        let key = try Self.read("Sources/NotesPlugin/Agent/ReviseModel.swift")
        #expect(key.contains("LLMLease.Key(modelID: modelFile.path, contextLength: contextLength)"))
        #expect(key.contains("priority: .background"))
    }

    /// Quit: `deactivate()` cancels the runs first and only then writes the buffers, so no half revision exists.
    @Test func deactivateCancelsTheRunsBeforeItFlushes() throws {
        let plugin = try Self.read("Sources/NotesPlugin/NotesPlugin.swift")
        let cancel = try #require(plugin.range(of: "await reviseService.cancelAll()"))
        let flush = try #require(plugin.range(of: "await documents.flushAll()"))
        #expect(cancel.lowerBound < flush.lowerBound)
    }

    @Test func theKeyIsBuiltFromTheFilePathAndTheNotesContext() {
        let file = URL(filePath: "/models/llm/qwen/model.gguf")
        let key = ReviseModelKey.make(modelFile: file)
        #expect(key == LLMLease.Key(modelID: "/models/llm/qwen/model.gguf", contextLength: 8192))
        #expect(LeasedReviseModel(modelURL: file).key == key)
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
