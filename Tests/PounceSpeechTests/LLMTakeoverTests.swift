import Foundation
import Testing

@testable import PounceSpeech

/// The takeover of a model from `background` leases by an `interactive` request of another context length, the
/// grace period after it, and the corner cases around both. No test waits for real time: the clock and the
/// keep-warm timer are fakes and every wait is a yield loop.
@Suite struct LLMTakeoverTests {
    let sleeper = ManualSleeper()
    let tracker = MemoryTracker()
    let clock = FakeClock()
    let lease: LLMLease
    let model = URL(filePath: "/models/llm/m.gguf")
    let grace = Duration.seconds(15)

    init() {
        let sleeper = sleeper
        let clock = clock
        lease = LLMLease(sleep: { try await sleeper.sleep($0) }, backgroundGrace: .seconds(15), now: { clock.now() })
    }

    private func take(
        _ runtime: LeaseLLM, priority: LeasePriority, on lease: LLMLease? = nil
    ) async throws -> LLMHandle {
        try await (lease ?? self.lease).acquire(
            key: .init(modelID: model.path, contextLength: runtime.contextLength), runtime: runtime, modelURL: model,
            priority: priority, keepWarm: { .seconds(60) })
    }

    private func ask(_ handle: LLMHandle, _ label: String) async throws -> GenerationResult {
        try await handle.generateResult(messages: [ChatMessage(role: "user", content: label)], maxTokens: 8)
    }

    private var dictationKey: LLMLease.Key { .init(modelID: model.path, contextLength: 4096) }

    // MARK: Victims in odd states

    @Test func aVictimThatIsStillLoadingIsGivenBackAsSoonAsItsLoadEnds() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let gate = notes.gateLoad()
        let pending = Task { try await take(notes, priority: .background) }
        await until { notes.loadsStarted == 1 }

        let interactive = Task { try await take(dictation, priority: .interactive) }
        await until { lease.takeovers == 1 }
        // Nothing else can take the model while the takeover waits for the victim, not even the same key.
        await #expect(throws: ModelLeaseError.busy) { try await take(notes, priority: .background) }
        await settle()
        #expect(dictation.loads.isEmpty)

        gate.open()
        let background = try await pending.value
        let holder = try await interactive.value
        #expect(background.wasYielded)
        #expect(dictation.loads == [model])
        #expect(notes.unloads == 1)
        #expect(tracker.peak == 1)
        #expect(lease.takeovers == 0)
        await #expect(throws: ModelLeaseError.yielded) { try await ask(background, "later") }
        #expect(await lease.activeLeases == 1)
        await background.release()
        await holder.release()
        #expect(await lease.activeLeases == 0)
    }

    @Test func aBackgroundRequestIsRefusedWhileATakeoverRunsEvenForTheSettledKey() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let background = try await take(notes, priority: .background)
        let gate = dictation.gateLoad()
        let interactive = Task { try await take(dictation, priority: .interactive) }
        await until { dictation.loadsStarted == 1 }
        #expect(lease.takeovers == 1)
        await #expect(throws: ModelLeaseError.busy) { try await take(notes, priority: .background) }
        await #expect(throws: ModelLeaseError.busy) { try await take(dictation, priority: .background) }
        gate.open()
        let holder = try await interactive.value
        #expect(lease.takeovers == 0)
        await holder.release()
        await background.release()
    }

    @Test func aVictimQueuedBehindItsOwnRunningRequestIsStoppedToo() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let background = try await take(notes, priority: .background)
        let running = Task { try await ask(background, "bg") }
        await until { notes.log == ["start bg"] }
        let queued = Task { try await ask(background, "other") }
        await until { lease.queued == 1 }

        let holder = try await take(dictation, priority: .interactive)
        await #expect(throws: ModelLeaseError.yielded) { try await running.value }
        await #expect(throws: ModelLeaseError.yielded) { try await queued.value }
        #expect(notes.log == ["start bg", "cancelled bg"])
        #expect(notes.unloads == 1)
        #expect(lease.queued == 0)
        #expect(tracker.peak == 1)
        await holder.release()
        await background.release()
        #expect(await lease.activeLeases == 0)
    }

    // MARK: Failure and cancellation

    @Test func aFailedLoadOfTheInteractiveModelLeavesNothingStuck() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let background = try await take(notes, priority: .background)
        dictation.state.withLock { $0.loadFails = true }
        await #expect(throws: LeaseEngine.LoadFailure.self) { try await take(dictation, priority: .interactive) }
        #expect(lease.takeovers == 0)
        #expect(await lease.activeLeases == 0)
        #expect(await lease.residentKey == nil)
        await background.release()

        // The background can take the model again, nothing is held busy.
        let again = try await take(notes, priority: .background)
        #expect(notes.loads.count == 2)
        #expect(try await ask(again, "x").text == "x#1")
        await again.release()
        #expect(await lease.activeLeases == 0)
        #expect(tracker.peak == 1)
    }

    @Test func anInteractiveRequestCancelledWhileTheVictimLoadsGivesNothingAndLeavesTheLeaseFree() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let gate = notes.gateLoad()
        let pending = Task { try await take(notes, priority: .background) }
        await until { notes.loadsStarted == 1 }
        let interactive = Task { try await take(dictation, priority: .interactive) }
        await until { lease.takeovers == 1 }

        interactive.cancel()
        await #expect(throws: CancellationError.self) { try await interactive.value }
        #expect(lease.takeovers == 0)
        #expect(dictation.loads.isEmpty)

        gate.open()
        let background = try await pending.value
        #expect(background.wasYielded)
        await background.release()
        #expect(await lease.activeLeases == 0)
        let again = try await take(notes, priority: .background)
        #expect(notes.loads.count == 1)
        await again.release()
    }

    @Test func anInteractiveRequestCancelledWhileItsModelLoadsReturnsNoHandleAndGivesTheLeaseBack() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let background = try await take(notes, priority: .background)
        let gate = dictation.gateLoad()
        let interactive = Task { try await take(dictation, priority: .interactive) }
        await until { dictation.loadsStarted == 1 }

        interactive.cancel()
        gate.open()
        await #expect(throws: CancellationError.self) { try await interactive.value }
        #expect(lease.takeovers == 0)
        #expect(await lease.activeLeases == 0)
        #expect(background.wasYielded)
        await background.release()
        #expect(tracker.peak == 1)
    }

    // MARK: Racing release and yield

    @Test func aReleaseRacingWithATakeoverNeverMakesAnInteractiveWaiterBusy() async throws {
        for _ in 0..<40 {
            let sleeper = ManualSleeper()
            let clock = clock
            let lease = LLMLease(sleep: { try await sleeper.sleep($0) }, now: { clock.now() })
            let tracker = MemoryTracker()
            let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
            let first = LeaseLLM(contextLength: 4096, tracker: tracker)
            let second = LeaseLLM(contextLength: 4096, tracker: tracker)
            let background = try await take(notes, priority: .background, on: lease)
            let release = Task { await background.release() }
            let a = Task { try await take(first, priority: .interactive, on: lease) }
            let b = Task { try await take(second, priority: .interactive, on: lease) }
            let handles = try await [a.value, b.value]
            await release.value
            #expect(await lease.activeLeases == 2)
            #expect(first.loads.count + second.loads.count == 1)
            #expect(tracker.peak == 1)
            for handle in handles { await handle.release() }
            #expect(await lease.activeLeases == 0)
            #expect(lease.takeovers == 0)
        }
    }

    // MARK: The grace period

    @Test func aBackgroundRequestDoesNotEvictAnIdleInteractiveResidentDuringTheGrace() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        await (try take(dictation, priority: .interactive)).release()

        clock.advance(.seconds(5))
        await #expect(throws: ModelLeaseError.busy) { try await take(notes, priority: .background) }
        #expect(notes.loads.isEmpty)
        #expect(dictation.isLoaded)
        #expect(dictation.unloads == 0)

        clock.advance(.seconds(10))  // 15 s since the release: the grace is over
        let handle = try await take(notes, priority: .background)
        #expect(dictation.unloads == 1)
        #expect(notes.loads == [model])
        #expect(tracker.peak == 1)
        await handle.release()
    }

    @Test func theGraceDoesNotHoldBackTheSameKeyAnInteractiveRequestOrAnEvictedModel() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let other = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        await (try take(dictation, priority: .interactive)).release()

        // The same key is shared.
        let shared = try await take(other, priority: .background)
        #expect(other.loads.isEmpty)
        await shared.release()

        // An interactive request is never held back.
        let interactive = try await take(notes, priority: .interactive)
        #expect(notes.loads == [model])
        await interactive.release()
        clock.advance(.seconds(1))

        // Once the model was unloaded (keep-warm over) there is nothing to protect.
        await until { sleeper.durations.count >= 1 }
        sleeper.fire()
        await until { await lease.residentKey == nil }
        let background = try await take(dictation, priority: .background)
        await background.release()
    }

    @Test func aReleaseOfABackgroundLeaseStartsNoGrace() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        await (try take(dictation, priority: .background)).release()
        let handle = try await take(notes, priority: .background)
        #expect(dictation.unloads == 1)
        await handle.release()
    }
}
