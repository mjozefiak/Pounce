import Foundation
import Synchronization
import Testing

@testable import LintelSpeech

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
        let again = try await take(engine)
        // Positive control: the first timer was cancelled by the new lease, not merely never started.
        await until { sleeper.cancelled == 1 }
        #expect(sleeper.durations.isEmpty)
        sleeper.fire()
        await settle()
        #expect(engine.unloads == 0)
        #expect(engine.loads == 1)
        // The timer of the next release is a live one: it does unload.
        await again.release()
        await until { sleeper.durations.count == 1 }
        sleeper.fire()
        await until { engine.unloads == 1 }
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
        // The old engine's timer was cancelled (positive control), so nothing unloads the new one.
        await until { sleeper.cancelled == 1 }
        sleeper.fire()
        await settle()
        #expect(new.unloads == 0)
        #expect(old.unloads == 1)
        await b.release()
        await until { sleeper.durations.count == 1 }
        sleeper.fire()
        await until { new.unloads == 1 }
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

    @Test func spellingsOfOneFolderShareOneKey() async throws {
        let first = LeaseEngine(tracker: tracker)
        let second = LeaseEngine(tracker: tracker)
        // A real folder under the temporary directory, which lives behind the /var -> /private/var link.
        let temporary = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let real = temporary.appending(path: "lintel-lease-\(UUID().uuidString)")
        // The same folder spelled through the /var link.
        let root = URL(filePath: real.path.hasPrefix("/private/var") ? String(real.path.dropFirst(8)) : real.path)
        let model = real.appending(path: "model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let a = try await take(first, in: URL(filePath: root.path + "/model"))
        let spellings = [
            URL(filePath: root.path + "/model/"),
            URL(filePath: model.path),
            URL(filePath: root.path + "/other/../model"),
            URL(filePath: root.path + "/./model/"),
        ]
        var leases = [a]
        for spelling in spellings {
            leases.append(try await take(second, in: spelling))
        }
        #expect(first.loads == 1)
        #expect(second.loads == 0)
        #expect(await lease.activeLeases == 5)
        let keys = Set(leases.map(\.key))
        #expect(keys.count == 1)
        for lease in leases { await lease.release() }
    }

    @Test func anUnloadWaitsForATranscriptionThatIsStillRunning() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let a = try await take(engine)
        engine.hold(1)
        let running = Task { try await a.transcribe(audio(1)) }
        await until { engine.started == [1] }
        // The lease is given back (recording cancelled) while Core ML is still busy with the segment.
        await a.release()
        let eviction = Task { await lease.evictIdle() }
        await until { await lease.residentKey == nil }
        await settle()
        #expect(engine.unloads == 0)
        #expect(engine.isLoaded)
        #expect(engine.finished.isEmpty)

        engine.letGo(1)
        _ = try await running.value
        await eviction.value
        #expect(engine.finished == [1])
        #expect(engine.unloads == 1)
    }

    @Test func aReplacementWaitsForARunningTranscriptionOfTheOldEngine() async throws {
        let old = LeaseEngine(tracker: tracker)
        let new = LeaseEngine(tracker: tracker)
        let a = try await take("parakeet", old)
        old.hold(1)
        let running = Task { try await a.transcribe(audio(1)) }
        await until { old.started == [1] }
        await a.release()
        let replacement = Task { try await take("whisper", new) }
        await until { await lease.residentKey?.modelID == "whisper" }
        await settle()
        #expect(old.unloads == 0)
        #expect(new.loads == 0)

        old.letGo(1)
        _ = try await running.value
        let b = try await replacement.value
        #expect(old.unloads == 1)
        #expect(new.loads == 1)
        #expect(tracker.peak == 1)
        await b.release()
    }

    @Test func aTranscriptionCannotStartOnceTheLeaseIsReleased() async throws {
        let engine = LeaseEngine(tracker: tracker)
        let a = try await take(engine)
        await a.release()
        await #expect(throws: ModelLeaseError.released) { try await a.transcribe(audio(1)) }
        #expect(engine.started.isEmpty)
        // Nothing is left counted as in flight: the unload is not held up.
        await lease.evictIdle()
        #expect(engine.unloads == 1)
    }

    @Test func aKeepWarmTimerThatFiresAfterANewLeaseWasTakenDoesNothing() async throws {
        // A sleep that ignores cancellation, so the old timer really does fire late.
        let gates = Mutex<[Latch]>([])
        let racing = SpeechEngineLease(sleep: { _ in
            let gate = Latch()
            gates.withLock { $0.append(gate) }
            await gate.wait()
        })
        let engine = LeaseEngine(tracker: tracker)
        func take() async throws -> SpeechLease {
            try await racing.acquire(
                modelID: "m", folder: folder, engine: engine, priority: .interactive, keepWarm: { .seconds(1) })
        }
        let first = try await take()
        await first.release()
        await until { gates.withLock { $0.count } == 1 }
        let second = try await take()
        gates.withLock { $0[0] }.open()
        await settle()
        #expect(engine.unloads == 0)
        #expect(await racing.activeLeases == 1)

        // After a second release the stale first timer must not count either; the second one does.
        await second.release()
        await until { gates.withLock { $0.count } == 2 }
        await settle()
        #expect(engine.unloads == 0)
        gates.withLock { $0[1] }.open()
        await until { engine.unloads == 1 }
        #expect(await racing.residentKey == nil)
    }

    @Test func clientsAcquiringTheSameKeyDuringALoadShareIt() async throws {
        let engine = LeaseEngine(tracker: tracker)
        engine.gateLoad()
        let first = Task { try await take(engine) }
        await until { engine.loadsStarted == 1 }
        let second = Task { try await take(LeaseEngine(tracker: tracker), priority: .background) }
        await until { await lease.activeLeases == 2 }
        await settle()
        // Neither has a lease before the engine is loaded.
        #expect(engine.loads == 0)
        engine.openLoad()
        let a = try await first.value
        let b = try await second.value
        #expect(engine.loads == 1)
        #expect(engine.loadsStarted == 1)
        #expect(await lease.activeLeases == 2)
        await a.release()
        await b.release()
    }

    @Test func whenALoadFailsEveryWaitingClientFailsAndTheEngineIsFreed() async throws {
        let engine = LeaseEngine(tracker: tracker)
        engine.gateLoad()
        engine.state.withLock { $0.failsToLoad = true }
        let first = Task { try await take(engine) }
        await until { engine.loadsStarted == 1 }
        let second = Task { try await take(engine, priority: .background) }
        await until { await lease.activeLeases == 2 }
        engine.openLoad()
        await #expect(throws: LeaseEngine.LoadFailure.self) { try await first.value }
        await #expect(throws: LeaseEngine.LoadFailure.self) { try await second.value }
        #expect(await lease.activeLeases == 0)
        #expect(await lease.residentKey == nil)
        // The partly loaded engine is unloaded, once, when the last claim on it is gone.
        await lease.evictIdle()
        #expect(engine.unloads == 1)
    }

    @Test func aStillRunningUnloadFinishesBeforeTheNextLoadStarts() async throws {
        let old = LeaseEngine(tracker: tracker)
        let new = LeaseEngine(tracker: tracker)
        old.gateUnload()
        await (try take("parakeet", old)).release()
        let replacement = Task { try await take("whisper", new) }
        await until { old.unloadsStarted == 1 }
        await settle()
        #expect(new.loadsStarted == 0)
        old.openUnload()
        let b = try await replacement.value
        #expect(old.unloads == 1)
        #expect(new.loads == 1)
        #expect(tracker.peak == 1)
        await b.release()
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
        // `take` is interactive here: the grace period only holds back `background`.
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

    @Test func anInteractiveRequestForAnotherContextLengthTakesTheModelFromABackgroundLease() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let background = try await take(notes, priority: .background)
        let running = Task { try await ask(background, "bg") }
        await until { notes.log == ["start bg"] }

        let interactive = try await take(dictation, priority: .interactive)
        #expect(notes.log == ["start bg", "cancelled bg"])
        #expect(notes.unloads == 1)
        #expect(dictation.loads == [model])
        #expect(tracker.peak == 1)
        await #expect(throws: ModelLeaseError.yielded) { try await running.value }
        #expect(background.wasYielded)
        await #expect(throws: ModelLeaseError.yielded) { try await ask(background, "later") }
        #expect(await lease.residentKey == .init(modelID: model.path, contextLength: 4096))
        #expect(await lease.activeLeases == 1)

        // The notes cannot take the model back while dictation holds it; after the release they can.
        await #expect(throws: ModelLeaseError.busy) { try await take(notes, priority: .background) }
        #expect(try await ask(interactive, "int").text == "int#1")
        await interactive.release()
        clock.advance(grace)
        let again = try await take(notes, priority: .background)
        #expect(notes.loads.count == 2)
        #expect(dictation.unloads == 1)
        #expect(try await ask(again, "bg").text == "bg#2")
        #expect(tracker.peak == 1)
        await again.release()
        await background.release()
        #expect(await lease.activeLeases == 0)
    }

    @Test func anIdleBackgroundLeaseIsAlsoGivenUpForAnInteractiveRequest() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let background = try await take(notes, priority: .background)
        let interactive = try await take(dictation, priority: .interactive)
        #expect(background.wasYielded)
        #expect(tracker.peak == 1)
        await interactive.release()
        await background.release()
        #expect(await lease.activeLeases == 0)
    }

    @Test func anotherModelFileIsStillBusyAndTheBackgroundGenerationKeepsRunning() async throws {
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let other = LeaseLLM(contextLength: 4096, tracker: tracker)
        let background = try await take(notes, priority: .background)
        let running = Task { try await ask(background, "bg") }
        await until { notes.log == ["start bg"] }
        await #expect(throws: ModelLeaseError.busy) {
            try await lease.acquire(
                key: .init(modelID: "/models/llm/other.gguf", contextLength: 4096), runtime: other,
                modelURL: URL(filePath: "/models/llm/other.gguf"), priority: .interactive, keepWarm: { .seconds(60) })
        }
        #expect(!background.wasYielded)
        #expect(notes.log == ["start bg"])
        #expect(other.loads.isEmpty)
        running.cancel()
        _ = try? await running.value
        await background.release()
    }

    @Test func aBackgroundRequestCannotTakeTheModelBackFromAnInteractiveHolder() async throws {
        let dictation = LeaseLLM(contextLength: 4096, tracker: tracker)
        let notes = LeaseLLM(contextLength: 8192, tracker: tracker)
        let interactive = try await take(dictation, priority: .interactive)
        await #expect(throws: ModelLeaseError.busy) { try await take(notes, priority: .background) }
        #expect(!interactive.wasYielded)
        #expect(notes.loads.isEmpty)
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

    @Test func aGenerationThatIsRunningHoldsUpTheUnload() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        let background = try await take(runtime, priority: .background)
        let running = Task { try await ask(background, "bg") }
        await until { runtime.log == ["start bg"] }
        await background.release()
        let eviction = Task { await lease.evictIdle() }
        await until { await lease.residentKey == nil }
        await settle()
        #expect(runtime.unloads == 0)
        #expect(runtime.isLoaded)
        // Positive control: once the generation ends (cancelled here), the unload goes through.
        running.cancel()
        _ = try? await running.value
        await eviction.value
        #expect(runtime.unloads == 1)
    }

    @Test func isInUseFollowsTheLeasesOfAModelFile() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        #expect(await !lease.isInUse(modelID: model.path))
        let handle = try await take(runtime)
        #expect(await lease.isInUse(modelID: model.path))
        #expect(await !lease.isInUse(modelID: "/other.gguf"))
        await handle.release()
        #expect(await !lease.isInUse(modelID: model.path))
    }

    @Test func aPreemptionThatArrivesBeforeTheTaskIsAttachedCancelsItOnAttach() async {
        let preemption = Preemption()
        preemption.fire()
        #expect(preemption.fired)
        let task = Task<GenerationResult, any Error> {
            try await Task.sleep(for: .seconds(3600))
            return GenerationResult(text: "", stoppedByTokenLimit: false)
        }
        preemption.attach(task)
        await #expect(throws: CancellationError.self) { try await task.value }

        // The other order: attached first, fired later.
        let later = Preemption()
        let second = Task<GenerationResult, any Error> {
            try await Task.sleep(for: .seconds(3600))
            return GenerationResult(text: "", stoppedByTokenLimit: false)
        }
        later.attach(second)
        #expect(!second.isCancelled)
        later.fire()
        await #expect(throws: CancellationError.self) { try await second.value }
    }

    @Test func aFailedLoadFreesTheRuntime() async throws {
        let runtime = LeaseLLM(tracker: tracker)
        runtime.state.withLock { $0.loadFails = true }
        await #expect(throws: LeaseEngine.LoadFailure.self) { try await take(runtime) }
        #expect(await lease.activeLeases == 0)
        await lease.evictIdle()
        #expect(runtime.unloads == 1)
    }
}
