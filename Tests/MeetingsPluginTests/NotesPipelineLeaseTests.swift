import Foundation
import PounceSpeech
import Testing

@testable import MeetingsPlugin

/// The pipeline on a real `LLMLease` with a scripted runtime: preemption by dictation, a busy model,
/// cancellation, timeouts and a model that does not load.
@Suite struct NotesPipelineLeaseTests {
    private func hang() async throws -> GenerationResult {
        try await Task.sleep(for: .seconds(3600))
        return .done("")
    }

    @Test func dictationPreemptsTheNotesAndTheyResumeAfterIt() async throws {
        let started = Flag()
        let rig = NotesRig { call, messages, _ in
            if messages.first?.content == "interactive" { return .done("dictation") }
            if call == 1 {
                started.set()
                return try await hang()  // cancelled between two tokens by the lease
            }
            return .done(NotesFake.answer(messages))
        }
        let pipeline = rig.pipeline()
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting()) }
        await notesEventually { started.isSet }

        let dictation = try await rig.lease.acquire(
            key: rig.model.key, runtime: rig.llm, modelURL: rig.url, priority: .interactive, keepWarm: { .seconds(60) })
        let answer = try await dictation.generateResult(
            messages: [ChatMessage(role: "system", content: "interactive")], maxTokens: 8)
        #expect(answer.text == "dictation")
        await dictation.release()

        let result = try await notes.value
        // The interrupted request is not a failure and not a retry: it simply ran again after dictation.
        #expect(result.status == .ok)
        #expect(result.failedChunks.isEmpty)
        let calls = rig.llm.calls
        #expect(calls.count == 4)
        #expect(NotesFake.isMap(calls[0].messages))
        #expect(calls[1].messages.first?.content == "interactive")
        #expect(NotesFake.isMap(calls[2].messages))
        #expect(!NotesFake.lastUser(calls[2].messages).contains(NotesPrompt.formatReminder))
        #expect(NotesFake.isReduce(calls[3].messages))
        #expect(await rig.waitUntilReleased())
    }

    @Test func dictationWithItsOwnContextLengthTakesTheModelAndTheNotesResumeAfterIt() async throws {
        let started = Flag()
        let rig = NotesRig { call, messages, _ in
            if call == 1 {
                started.set()
                return try await hang()  // cancelled between two tokens
            }
            return .done(NotesFake.answer(messages))
        }
        let both = Flag()
        let dictationLLM = ScriptedLLM(contextLength: 4096) { [llm = rig.llm] _, _, _ in
            if llm.isLoaded { both.set() }  // two copies of the model in memory would show here
            return .done("dictation")
        }
        let log = NotesEventLog()
        let pipeline = rig.pipeline({ $0.busyPoll = .milliseconds(20) })
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add) }
        await notesEventually { started.isSet }

        let dictation = try await rig.lease.acquire(
            key: .init(modelID: rig.url.path, contextLength: 4096), runtime: dictationLLM, modelURL: rig.url,
            priority: .interactive, keepWarm: { .seconds(60) })
        #expect(!rig.llm.isLoaded)
        #expect(dictationLLM.isLoaded)
        let answer = try await dictation.generateResult(
            messages: [ChatMessage(role: "system", content: "interactive")], maxTokens: 8)
        #expect(answer.text == "dictation")
        #expect(!both.isSet)
        await dictation.release()

        let result = try await notes.value
        // The interrupted request is repeated: not a failure, not a retry, no format reminder.
        #expect(result.status == .ok)
        #expect(result.failedChunks.isEmpty)
        let calls = rig.llm.calls
        #expect(calls.count == 3)
        #expect(NotesFake.isMap(calls[0].messages))
        #expect(NotesFake.isMap(calls[1].messages))
        #expect(!NotesFake.lastUser(calls[1].messages).contains(NotesPrompt.formatReminder))
        #expect(NotesFake.isReduce(calls[2].messages))
        #expect(await rig.waitUntilReleased())
        #expect(rig.llm.isLoaded)
        #expect(!dictationLLM.isLoaded)
    }

    @Test func aDifferentModelFileOfDictationDoesNotInterruptTheNotes() async throws {
        let started = Flag()
        let proceed = Flag()
        let rig = NotesRig { _, messages, _ in
            started.set()
            while !proceed.isSet { try await Task.sleep(for: .milliseconds(5)) }
            return .done(NotesFake.answer(messages))
        }
        let other = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let notes = Task { try await rig.pipeline().run(utterances: NotesFixtures.meeting()) }
        await notesEventually { started.isSet }
        await #expect(throws: ModelLeaseError.busy) {
            _ = try await rig.lease.acquire(
                key: .init(modelID: "/models/llm/other.gguf", contextLength: 4096), runtime: other,
                modelURL: URL(filePath: "/models/llm/other.gguf"), priority: .interactive, keepWarm: { .seconds(60) })
        }
        proceed.set()
        let result = try await notes.value
        #expect(result.status == .ok)
        #expect(rig.llm.calls.count == 2)
        #expect(await rig.waitUntilReleased())
    }

    @Test func aBusyModelMakesTheNotesWaitAndThenRun() async throws {
        let rig = NotesRig()
        let other = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let dictation = try await rig.lease.acquire(
            key: .init(modelID: rig.url.path, contextLength: 4096), runtime: other, modelURL: rig.url,
            priority: .interactive, keepWarm: { .seconds(60) })
        let log = NotesEventLog()
        let pipeline = rig.pipeline(
            { $0.busyPoll = .seconds(7) },
            sleep: { duration in
                if duration == .seconds(7) {
                    await dictation.release()  // dictation is done by the time we ask again
                } else {
                    try await Task.sleep(for: duration)
                }
            })
        let result = try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add)
        #expect(result.status == .ok)
        #expect(log.all.first == .waitingForModel)
        #expect(log.all.filter { $0 == .waitingForModel }.count == 1)
        #expect(await rig.waitUntilReleased())
    }

    @Test func aModelThatStaysBusyEndsInAnError() async throws {
        let rig = NotesRig()
        let other = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let dictation = try await rig.lease.acquire(
            key: .init(modelID: rig.url.path, contextLength: 4096), runtime: other, modelURL: rig.url,
            priority: .interactive, keepWarm: { .seconds(60) })
        let log = NotesEventLog()
        let pipeline = rig.pipeline(
            {
                $0.busyPoll = .seconds(7)
                $0.busyLimit = .seconds(14)
            }, sleep: { _ in })
        await #expect(throws: NotesFailure.modelBusy) {
            _ = try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add)
        }
        #expect(log.all == [.waitingForModel, .waitingForModel])
        #expect(rig.llm.calls.isEmpty)
        await dictation.release()
    }

    @Test func cancellingStopsTheNotesAndGivesTheModelBack() async throws {
        let started = Flag()
        let rig = NotesRig { _, _, _ in
            started.set()
            return try await hang()
        }
        let pipeline = rig.pipeline()
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting()) }
        await notesEventually { started.isSet }
        notes.cancel()
        await #expect(throws: CancellationError.self) { _ = try await notes.value }
        #expect(await rig.waitUntilReleased())
        #expect(rig.llm.calls.count == 1)
    }

    @Test func cancellingBetweenChunksStopsBeforeTheNextRequest() async throws {
        let first = Flag()
        let release = Flag()
        let rig = NotesRig { _, messages, _ in
            first.set()
            while !release.isSet { try await Task.sleep(for: .milliseconds(5)) }
            return .done(NotesFake.answer(messages))
        }
        let pipeline = rig.pipeline({ $0.chunkTokens = 150 })
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.filler(count: 20)) }
        await notesEventually { first.isSet }
        notes.cancel()
        release.set()
        await #expect(throws: CancellationError.self) { _ = try await notes.value }
        #expect(rig.llm.calls.count <= 2)
        #expect(await rig.waitUntilReleased())
    }

    @Test func aRequestThatTimesOutIsRetriedOnce() async throws {
        let rig = NotesRig { call, messages, _ in
            if call == 1 { return try await hang() }
            return .done(NotesFake.answer(messages))
        }
        let pipeline = rig.pipeline(
            { $0.mapTimeout = .seconds(11) },
            sleep: { duration in
                // The map timer fires soon; every other wait is for real.
                try await Task.sleep(for: duration == .seconds(11) ? .milliseconds(100) : duration)
            })
        let result = try await pipeline.run(utterances: NotesFixtures.meeting())
        #expect(result.status == .ok)
        #expect(rig.llm.calls.count == 3)
        #expect(await rig.waitUntilReleased())
    }

    @Test func aRequestThatAlwaysTimesOutFailsTheChunk() async throws {
        let rig = NotesRig { _, _, _ in try await hang() }
        let pipeline = rig.pipeline(
            { $0.mapTimeout = .seconds(11) },
            sleep: { duration in
                try await Task.sleep(for: duration == .seconds(11) ? .milliseconds(50) : duration)
            })
        let result = try await pipeline.run(utterances: NotesFixtures.meeting())
        #expect(result.status == .failed)
        #expect(result.failedChunks == ["c1"])
        #expect(rig.llm.calls.count == 2)
    }

    @Test func aModelThatDoesNotLoadIsReported() async throws {
        let rig = NotesRig()
        rig.llm.failLoading()
        await #expect(throws: NotesFailure.modelUnavailable) {
            _ = try await rig.pipeline().run(utterances: NotesFixtures.meeting())
        }
        #expect(rig.llm.calls.isEmpty)
        #expect(await rig.waitUntilReleased())
    }

    @Test func theModelStaysResidentForTheNextRunAndIsSharedWithDictation() async throws {
        let rig = NotesRig()
        _ = try await rig.pipeline().run(utterances: NotesFixtures.meeting())
        #expect(rig.llm.isLoaded)
        #expect(await rig.lease.residentKey == rig.model.key)
        #expect(rig.model.key.contextLength == 8192)
        #expect(rig.model.key.modelID == rig.url.path)
    }
}
