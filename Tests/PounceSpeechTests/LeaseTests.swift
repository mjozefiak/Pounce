import Foundation
import Synchronization
import Testing

@testable import PounceSpeech

private let folder = URL(filePath: "/models/speech/a")

@Suite struct SpeechEngineLeaseTests {
    let sleeper = ManualSleeper()
    let tracker = MemoryTracker()
    let lease: SpeechEngineLease

    init() {
        let sleeper = sleeper
        lease = SpeechEngineLease(sleep: { try await sleeper.sleep($0) })
    }

    private func take(
        _ engine: LeaseEngine, priority: LeasePriority = .interactive, in folder: URL = folder,
        keepWarm: Duration = .seconds(60)
    ) async throws -> SpeechLease {
        try await take("parakeet", engine, priority: priority, in: folder, keepWarm: keepWarm)
    }

    private func take(
        _ id: String, _ engine: LeaseEngine, priority: LeasePriority = .interactive,
        in folder: URL = folder, keepWarm: Duration = .seconds(60)
    ) async throws -> SpeechLease {
        try await lease.acquire(
            modelID: id, folder: folder, engine: engine, priority: priority, keepWarm: { keepWarm })
    }

    @Test func theSameKeyIsSharedAndLoadedOnce() async throws {
        let first = LeaseEngine(tracker: tracker)
        let second = LeaseEngine(tracker: tracker)
        let a = try await take(first)
        let b = try await take(second, priority: .background)
        #expect(first.loads == 1)
        #expect(second.loads == 0)
        #expect(await lease.activeLeases == 2)

        // The second client transcribes with the engine that is already in memory.
        #expect(try await b.transcribe(audio(7)) == .transcript(TranscriptSegment(text: "segment 7")))
        #expect(first.finished == [7])
        #expect(second.started.isEmpty)

        // The keep-warm time counts from the release of the last lease.
        await a.release()
        #expect(sleeper.durations.isEmpty)
        await b.release()
        await until { sleeper.durations == [.seconds(60)] }
        #expect(sleeper.durations == [.seconds(60)])
        #expect(first.isLoaded)
    }

    @Test func theEngineIsUnloadedAfterTheKeepWarmTime() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let a = try await take(engine, keepWarm: .seconds(600))
        await a.release()
        await until { sleeper.durations == [.seconds(600)] }
        #expect(sleeper.durations == [.seconds(600)])
        #expect(engine.unloads == 0)
        sleeper.fire()
        await until { engine.unloads == 1 }
        #expect(engine.unloads == 1)
        #expect(await lease.residentKey == nil)
    }

    @Test func aNewLeaseCancelsTheKeepWarmTimer() async throws {
        let engine = LeaseEngine(tracker: tracker)
        await (try take(engine)).release()
        await until { sleeper.durations.count == 1 }
        #expect(sleeper.durations.count == 1)
        let again = try await take(engine)
        await until { sleeper.durations.isEmpty }
        #expect(sleeper.durations.isEmpty)
        sleeper.fire()
        #expect(engine.unloads == 0)
        #expect(engine.loads == 1)
        await again.release()
    }

    @Test func aWarmEngineWithoutALeaseIsReplacedAtOnce() async throws {
        let old = LeaseEngine(tracker: tracker)
        let new = LeaseEngine(tracker: tracker)
        await (try take("parakeet", old)).release()
        let b = try await take("whisper", new)
        #expect(old.unloads == 1)
        #expect(new.loads == 1)
        #expect(tracker.peak == 1)
        #expect(await lease.residentKey == .init(modelID: "whisper", folder: folder))
        // The old engine's timer is gone: nothing unloads the new one.
        await until { sleeper.durations.isEmpty }
        sleeper.fire()
        #expect(new.unloads == 0)
        await b.release()
    }

    @Test func anotherKeyWhileALeaseIsActiveIsBusy() async throws {
        let first = LeaseEngine(tracker: tracker)
        let other = LeaseEngine(tracker: tracker)
        let a = try await take("parakeet", first)
        await #expect(throws: ModelLeaseError.busy) { try await take("whisper", other) }
        await #expect(throws: ModelLeaseError.busy) {
            try await take("parakeet", other, in: URL(filePath: "/models/speech/elsewhere"))
        }
        #expect(other.loads == 0)
        #expect(first.isLoaded)
        #expect(first.unloads == 0)
        #expect(await lease.activeLeases == 1)

        await a.release()
        let b = try await take("whisper", other)
        #expect(first.unloads == 1)
        #expect(other.loads == 1)
        await b.release()
    }

    @Test func aFailedLoadGivesTheLeaseBack() async throws {
        let broken = LeaseEngine(tracker: tracker)
        broken.state.withLock { $0.failsToLoad = true }
        await #expect(throws: LeaseEngine.LoadFailure.self) { try await take("parakeet", broken) }
        #expect(await lease.activeLeases == 0)
        #expect(await lease.residentKey == nil)
        let fine = LeaseEngine(tracker: tracker)
        await (try take("whisper", fine)).release()
        #expect(fine.loads == 1)
    }

    @Test func onLoadingIsCalledOnlyWhenAnEngineIsLoaded() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let calls = Mutex(0)
        let a = try await lease.acquire(
            modelID: "m", folder: folder, engine: engine, priority: .interactive, keepWarm: { .zero },
            onLoading: { calls.withLock { $0 += 1 } })
        let b = try await lease.acquire(
            modelID: "m", folder: folder, engine: engine, priority: .interactive, keepWarm: { .zero },
            onLoading: { calls.withLock { $0 += 1 } })
        #expect(calls.withLock { $0 } == 1)
        await a.release()
        await b.release()
    }

    @Test func aReleasedLeaseCannotTranscribe() async throws {
        let a = try await take(LeaseEngine(tracker: tracker))
        await a.release()
        await a.release()
        await #expect(throws: ModelLeaseError.released) { try await a.transcribe(audio(1)) }
        // Releasing twice gave back one lease, not two.
        await until { sleeper.durations.count == 1 }
        #expect(sleeper.durations.count == 1)
    }

    @Test func evictIdleUnloadsOnlyWhenNobodyHoldsALease() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let a = try await take(engine)
        await lease.evictIdle()
        #expect(engine.unloads == 0)
        await a.release()
        await lease.evictIdle()
        #expect(engine.unloads == 1)
        #expect(await lease.residentKey == nil)
    }

    @Test func interactiveRequestsGoBeforeQueuedBackgroundOnes() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let background = try await take(engine, priority: .background)
        let interactive = try await take(engine, priority: .interactive)
        engine.hold(1)
        let first = Task { try await background.transcribe(audio(1)) }
        await until { engine.started == [1] }
        let second = Task { try await background.transcribe(audio(2)) }
        await until { lease.queued == 1 }
        let third = Task { try await interactive.transcribe(audio(3)) }
        await until { lease.queued == 2 }

        engine.letGo(1)
        _ = try await (first.value, second.value, third.value)
        #expect(engine.started == [1, 3, 2])
        await background.release()
        await interactive.release()
    }

    @Test func theBackgroundQueueHoldsAMinuteOfUnfinishedAudio() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let background = try await take(engine, priority: .background)
        let interactive = try await take(engine, priority: .interactive)
        engine.hold(1)
        let running = Task { try await background.transcribe(audio(1, seconds: 40)) }
        await until { engine.started == [1] }
        let queued = Task { try await background.transcribe(audio(2, seconds: 20)) }
        await until { lease.queued == 1 }

        // 40 s running and 20 s waiting is the limit: the caller is told to spool.
        #expect(try await background.transcribe(audio(3, seconds: 1)) == .spool)
        #expect(engine.started == [1])

        // Dictation is never refused and goes first.
        let dictation = Task { try await interactive.transcribe(audio(4, seconds: 100)) }
        await until { lease.queued == 2 }
        engine.letGo(1)
        _ = try await (running.value, queued.value, dictation.value)
        #expect(engine.started == [1, 4, 2])

        // Once the queue has drained the background accepts audio again.
        #expect(try await background.transcribe(audio(5, seconds: 30)) == .transcript(.init(text: "segment 5")))
        await background.release()
        await interactive.release()
    }

    @Test func aCancelledQueuedSegmentFreesItsPlaceInTheQueue() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let background = try await take(engine, priority: .background)
        engine.hold(1)
        let running = Task { try await background.transcribe(audio(1, seconds: 40)) }
        await until { engine.started == [1] }
        let queued = Task { try await background.transcribe(audio(2, seconds: 20)) }
        await until { lease.queued == 1 }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(lease.queued == 0)

        // 40 s are still running; the cancelled 20 s no longer count.
        let later = Task { try await background.transcribe(audio(3, seconds: 15)) }
        await until { lease.queued == 1 }
        engine.letGo(1)
        _ = try await (running.value, later.value)
        #expect(engine.started == [1, 3])
        await background.release()
    }
}

@Suite struct LLMLeaseTests {
    let sleeper = ManualSleeper()
    let tracker = MemoryTracker()
    let lease: LLMLease
    let model = URL(filePath: "/models/llm/m.gguf")

    init() {
        let sleeper = sleeper
        lease = LLMLease(sleep: { try await sleeper.sleep($0) })
    }

    private func take(
        _ runtime: LeaseLLM, context: Int? = nil, priority: LeasePriority = .interactive,
        keepWarm: Duration = .seconds(60)
    ) async throws -> LLMHandle {
        try await lease.acquire(
            key: .init(modelID: model.path, contextLength: context ?? runtime.contextLength), runtime: runtime,
            modelURL: model, priority: priority, keepWarm: { keepWarm })
    }

    private func ask(_ handle: LLMHandle, _ label: String) async throws -> GenerationResult {
        try await handle.generateResult(messages: [ChatMessage(role: "user", content: label)], maxTokens: 8)
    }

    @Test func theSameKeyIsSharedAndLoadedOnce() async throws {
        let first = LeaseLLM(tracker: tracker)
        let second = LeaseLLM(tracker: tracker)
        let a = try await take(first)
        let b = try await take(second, priority: .background)
        #expect(first.loads == [model])
        #expect(second.loads.isEmpty)
        #expect(try await ask(b, "x").text == "x#1")
        #expect(second.log.isEmpty)
        await a.release()
        #expect(sleeper.durations.isEmpty)
        await b.release()
        await until { sleeper.durations == [.seconds(60)] }
        #expect(sleeper.durations == [.seconds(60)])
    }

    @Test func aDifferentContextLengthLoadsOnlyAfterTheReleaseAndNeverTwoCopies() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let a = try await take(dictation)
        await #expect(throws: ModelLeaseError.busy) { try await take(notes) }
        #expect(notes.loads.isEmpty)
        #expect(dictation.isLoaded)

        await a.release()
        let b = try await take(notes)
        #expect(dictation.unloads == 1)
        #expect(notes.loads == [model])
        #expect(tracker.peak == 1)
        await b.release()
    }

    @Test func theModelIsUnloadedAfterTheKeepWarmTime() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        await (try take(runtime, keepWarm: .seconds(300))).release()
        await until { sleeper.durations == [.seconds(300)] }
        #expect(sleeper.durations == [.seconds(300)])
        #expect(runtime.isLoaded)
        sleeper.fire()
        await until { runtime.unloads == 1 }
        #expect(!runtime.isLoaded)
    }

    @Test func aRunningBackgroundGenerationIsCancelledForAnInteractiveOneAndRunsAgainAfterIt() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        let background = try await take(runtime, priority: .background)
        let interactive = try await take(runtime, priority: .interactive)
        let notes = Task { try await ask(background, "bg") }
        await until { runtime.log == ["start bg"] }

        let dictation = try await ask(interactive, "int")
        let summary = try await notes.value
        #expect(dictation.text == "int#1")
        #expect(summary.text == "bg#2")
        #expect(runtime.log == ["start bg", "cancelled bg", "start int", "done int", "start bg", "done bg"])
        await background.release()
        await interactive.release()
    }

    @Test func aBackgroundRequestDoesNotInterruptAnotherBackgroundOne() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        let background = try await take(runtime, priority: .background)
        let first = Task { try await ask(background, "bg") }
        await until { runtime.log == ["start bg"] }
        let second = Task { try await ask(background, "other") }
        await until { lease.queued == 1 }
        #expect(runtime.log == ["start bg"])
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value.text == "other#1")
        await background.release()
    }

    @Test func aCallerThatCancelsIsNotRetried() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        let background = try await take(runtime, priority: .background)
        let notes = Task { try await ask(background, "bg") }
        await until { runtime.log == ["start bg"] }
        notes.cancel()
        await #expect(throws: CancellationError.self) { try await notes.value }
        #expect(runtime.log == ["start bg", "cancelled bg"])
        await background.release()
    }
}
