import Foundation
import PounceSpeech
import Testing

@testable import MeetingsPlugin

/// What the notes do when dictation takes the model over: they wait, resume without a retry, never retry a real
/// cancel, fail fast when the model cannot be had, and give up after too many takeovers or too much waiting.
/// Nothing here waits for real time: the busy poll and the lease clock are driven by the test.
@Suite struct NotesPipelineTakeoverTests {
    private static let poll = Duration.seconds(7)

    private func hang() async throws -> GenerationResult {
        try await Task.sleep(for: .seconds(3600))
        return .done("")
    }

    private func dictationKey(_ rig: NotesRig) -> LLMLease.Key { .init(modelID: rig.url.path, contextLength: 4096) }

    private func takeOver(_ rig: NotesRig, with runtime: ScriptedLLM) async throws -> LLMHandle {
        try await rig.lease.acquire(
            key: dictationKey(rig), runtime: runtime, modelURL: rig.url, priority: .interactive,
            keepWarm: { .seconds(60) })
    }

    @Test func aCancelWhileTheNotesWaitForDictationEndsThemAtOnceWithoutARetry() async throws {
        let rig = NotesRig { _, _, _ in try await hang() }
        let dictationLLM = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let stepper = NotesStepper()
        let log = NotesEventLog()
        let pipeline = rig.pipeline({ $0.busyPoll = Self.poll }, sleep: rig.pollSleep(Self.poll, stepper))
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add) }
        await spin { rig.llm.calls.count == 1 }

        let dictation = try await takeOver(rig, with: dictationLLM)  // held: the notes cannot come back
        await spin { stepper.pending == 1 }
        #expect(log.all.contains(.waitingForModel))

        notes.cancel()
        await #expect(throws: CancellationError.self) { _ = try await notes.value }
        // The yield was no failure and the cancel is no yield: one request, never repeated.
        #expect(rig.llm.calls.count == 1)
        await dictation.release()
        await spin { await rig.lease.activeLeases == 0 }
    }

    @Test func aModelThatStaysBusyAfterATakeoverEndsTheJobWithoutRetryingTheChunk() async throws {
        let rig = NotesRig { _, _, _ in try await hang() }
        let dictationLLM = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let stepper = NotesStepper()
        let log = NotesEventLog()
        let pipeline = rig.pipeline(
            {
                $0.busyPoll = Self.poll
                $0.busyLimit = .seconds(14)
            }, sleep: rig.pollSleep(Self.poll, stepper))
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add) }
        await spin { rig.llm.calls.count == 1 }
        let dictation = try await takeOver(rig, with: dictationLLM)

        for _ in 0..<2 {
            await spin { stepper.pending == 1 }
            stepper.fire()
        }
        // `modelBusy` comes out of the job as it is: it is not a failed chunk that is tried once more.
        await #expect(throws: NotesFailure.modelBusy) { _ = try await notes.value }
        #expect(rig.llm.calls.count == 1)
        #expect(log.all.filter { $0 == .waitingForModel }.count == 2)
        await dictation.release()
        await spin { await rig.lease.activeLeases == 0 }
    }

    @Test func theBusyBudgetIsOneForTheWholeJobNotRestartedByATakeover() async throws {
        let rig = NotesRig { _, _, _ in try await hang() }
        let dictationLLM = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let stepper = NotesStepper()
        let log = NotesEventLog()
        let pipeline = rig.pipeline(
            {
                $0.busyPoll = .seconds(10)
                $0.busyLimit = .seconds(10)
            }, sleep: rig.pollSleep(.seconds(10), stepper))
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add) }
        await spin { rig.llm.calls.count == 1 }

        // First takeover: one wait (10 s) uses the whole budget, then the notes get the model back.
        await (try takeOver(rig, with: dictationLLM)).release()
        await spin { stepper.pending == 1 }
        rig.clock.advance(.seconds(15))
        stepper.fire()
        await spin { rig.llm.calls.count == 2 }

        // Second takeover: the budget is spent, so there is no new wait.
        let dictation = try await takeOver(rig, with: dictationLLM)
        await #expect(throws: NotesFailure.modelBusy) { _ = try await notes.value }
        #expect(log.all.filter { $0 == .waitingForModel }.count == 1)
        #expect(rig.llm.calls.count == 2)
        await dictation.release()
        await spin { await rig.lease.activeLeases == 0 }
    }

    @Test func aRequestThatDictationKeepsInterruptingGivesUpAfterTheYieldCap() async throws {
        let rig = NotesRig { _, _, _ in try await hang() }
        let dictationLLM = ScriptedLLM(contextLength: 4096) { _, _, _ in .done("") }
        let stepper = NotesStepper()
        let log = NotesEventLog()
        let pipeline = rig.pipeline(
            {
                $0.busyPoll = Self.poll
                $0.busyLimit = .seconds(1_000_000)
            }, sleep: rig.pollSleep(Self.poll, stepper))
        let notes = Task { try await pipeline.run(utterances: NotesFixtures.meeting(), onEvent: log.add) }
        let cap = NotesLease.maxYieldsPerRequest

        for round in 1...(cap + 1) {
            await spin { rig.llm.calls.count == round }
            await (try takeOver(rig, with: dictationLLM)).release()
            if round <= cap {
                // Not a failure and not a retry: the same request is generated again after the grace period.
                await spin { stepper.pending == 1 }
                rig.clock.advance(.seconds(15))
                stepper.fire()
            }
        }
        await #expect(throws: NotesFailure.modelBusy) { _ = try await notes.value }
        #expect(rig.llm.calls.count == cap + 1)
        await spin { await rig.lease.activeLeases == 0 }
    }
}
