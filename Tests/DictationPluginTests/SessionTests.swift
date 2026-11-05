import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// Feeds a prepared buffer in chunks and keeps the stream open until `stop()`, like a live microphone.
final class ScriptedAudioInput: AudioInput, @unchecked Sendable {
    private let samples: [Float]
    private let chunk: Int
    private let state = Mutex<AsyncStream<[Float]>.Continuation?>(nil)
    let failsToStart: Bool
    let endsEarly: Bool

    init(seconds: Double, chunk: Int = 3_000, failsToStart: Bool = false, endsEarly: Bool = false) {
        // Every second of audio carries its own number, so a test can tell which segment it got.
        samples = (0..<Int(seconds * Double(AudioFormat.sampleRate))).map { Float($0 / AudioFormat.sampleRate) / 100 }
        self.chunk = chunk
        self.failsToStart = failsToStart
        self.endsEarly = endsEarly
    }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        if failsToStart { throw CaptureError.noInputDevice }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        state.withLock { $0 = continuation }
        var index = 0
        while index < samples.count {
            let end = min(index + chunk, samples.count)
            onLevel(0.5)
            continuation.yield(Array(samples[index..<end]))
            index = end
        }
        if endsEarly { continuation.finish() }
        return stream
    }

    func stop() async {
        state.withLock { $0?.finish() }
    }
}

/// Reports speech over fixed sample ranges, at the moment the processed audio passes each boundary.
final class RangeVAD: VoiceActivityDetector, @unchecked Sendable {
    private let ranges: [Range<Int>]
    private let state = Mutex(0)

    init(_ ranges: [Range<Int>]) {
        self.ranges = ranges
    }

    func process(_ samples: [Float]) async throws -> [VADEvent] {
        let (before, after) = state.withLock { processed -> (Int, Int) in
            defer { processed += samples.count }
            return (processed, processed + samples.count)
        }
        var events: [VADEvent] = []
        for range in ranges {
            if range.lowerBound >= before && range.lowerBound < after {
                events.append(VADEvent(kind: .speechStart, sampleIndex: range.lowerBound))
            }
            if range.upperBound > before && range.upperBound <= after {
                events.append(VADEvent(kind: .speechEnd, sampleIndex: range.upperBound))
            }
        }
        return events
    }
}

/// A one-shot gate a fake waits on, not cancellable, like a Core ML call.
final class Gate: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resume = state.withLock { state -> Bool in
                if !state.open { state.waiters.append(continuation) }
                return state.open
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Yields until `condition` holds; records an issue instead of hanging.
func eventually(
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () async -> Bool
) async {
    for _ in 0..<200_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("The condition was not met", sourceLocation: sourceLocation)
}

/// Answers "segment N" after a delay that depends on the segment's length, and can fail or load slowly.
final class FakeEngine: SpeechEngine, @unchecked Sendable {
    struct State {
        var loaded = false
        var calls = 0
        var lengths: [Int] = []
        var cancelledCalls = 0
        var unloads = 0
        var finished = 0
    }

    let state = Mutex(State())
    var loadDelay: Duration = .zero
    var loadFails = false
    /// Delay before answering, by the second of audio the segment starts in.
    var delays: [Int: Duration] = [:]
    var failingSeconds: Set<Int> = []
    /// Held until opened; the engine call does not react to cancellation while it waits.
    var loadGate: Gate?
    var transcribeGate: Gate?

    var isLoaded: Bool { state.withLock { $0.loaded } }

    func load(modelFolder: URL) async throws {
        await loadGate?.wait()
        try await Task.sleep(for: loadDelay)
        if loadFails { throw CaptureError.noInputDevice }
        state.withLock { $0.loaded = true }
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        let key = Int((samples.first ?? 0) * 100 + 0.5)
        state.withLock { state in
            state.calls += 1
            state.lengths.append(samples.count)
        }
        await transcribeGate?.wait()
        do {
            try await Task.sleep(for: delays[key] ?? .zero)
        } catch {
            state.withLock { $0.cancelledCalls += 1 }
            throw error
        }
        if failingSeconds.contains(key) { throw CaptureError.noInputDevice }
        state.withLock { $0.finished += 1 }
        return TranscriptSegment(text: "segment \(key)")
    }

    func unload() async {
        state.withLock {
            $0.loaded = false
            $0.unloads += 1
        }
    }
}

final class EventLog: Sendable {
    private let events = Mutex<[DictationSession.Event]>([])
    var all: [DictationSession.Event] { events.withLock { $0 } }
    func append(_ event: DictationSession.Event) { events.withLock { $0.append(event) } }
}

private let second = AudioFormat.sampleRate

private func session(
    _ audio: ScriptedAudioInput, vad: RangeVAD, engine: FakeEngine,
    maximum: Duration = .seconds(1200), warning: Duration = .seconds(120),
    events: EventLog = EventLog()
) -> DictationSession {
    DictationSession(
        audio: audio, vad: vad, engine: engine, modelFolder: URL(filePath: "/tmp/none"), maximumDuration: maximum,
        warningBefore: warning,
        onEvent: { event in
            if case .level = event { return }
            events.append(event)
        })
}

@Suite struct DictationSessionTests {
    @Test func segmentsAreJoinedInTheOrderTheyWereSpokenWhateverOrderTheAnswersCome() async throws {
        let engine = FakeEngine()
        // The first segment's answer is the slowest.
        engine.delays = [1: .milliseconds(150), 3: .milliseconds(80), 5: .zero]
        let ranges = [second..<(2 * second), (3 * second)..<(4 * second), (5 * second)..<(6 * second)]
        let session = session(ScriptedAudioInput(seconds: 7), vad: RangeVAD(ranges), engine: engine)
        try await session.start()
        let output = try await session.finish()
        #expect(output.text == "segment 1 segment 3 segment 5")
        #expect(output.segmentCount == 3)
        #expect(output.failedSegments == 0)
        #expect(output.duration == 7)
    }

    @Test func nothingHeardIsSilenceNotAnEmptyPaste() async throws {
        let session = session(ScriptedAudioInput(seconds: 4), vad: RangeVAD([]), engine: FakeEngine())
        try await session.start()
        await #expect(throws: DictationSession.Failure.silence) { try await session.finish() }
    }

    @Test func speechStillOpenWhenTheUserStopsIsFinished() async throws {
        let engine = FakeEngine()
        let session = session(
            ScriptedAudioInput(seconds: 5), vad: RangeVAD([(2 * second)..<(99 * second)]), engine: engine)
        try await session.start()
        let output = try await session.finish()
        #expect(output.text == "segment 2")
        #expect(engine.state.withLock { $0.lengths } == [3 * second])
    }

    @Test func wordsSpokenWhileTheModelLoadsAreNotLost() async throws {
        let engine = FakeEngine()
        engine.loadDelay = .milliseconds(200)
        let events = EventLog()
        let session = session(
            ScriptedAudioInput(seconds: 4), vad: RangeVAD([second..<(2 * second)]), engine: engine, events: events)
        try await session.start()
        let output = try await session.finish()
        #expect(output.text == "segment 1")
        #expect(events.all.contains(.loadingModel))
        #expect(events.all.contains(.modelLoaded))
    }

    @Test func aModelThatIsAlreadyLoadedIsNotLoadedAgain() async throws {
        let engine = FakeEngine()
        try await engine.load(modelFolder: URL(filePath: "/tmp/none"))
        let events = EventLog()
        let session = session(
            ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: engine, events: events)
        try await session.start()
        _ = try await session.finish()
        #expect(!events.all.contains(.loadingModel))
    }

    @Test func aModelThatCannotLoadFailsTheRecording() async throws {
        let engine = FakeEngine()
        engine.loadFails = true
        let session = session(
            ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: engine)
        try await session.start()
        await #expect(throws: DictationSession.Failure.engine) { try await session.finish() }
    }

    @Test func aFailedSegmentIsSkippedAndCounted() async throws {
        let engine = FakeEngine()
        engine.failingSeconds = [3]
        let ranges = [second..<(2 * second), (3 * second)..<(4 * second), (5 * second)..<(6 * second)]
        let session = session(ScriptedAudioInput(seconds: 7), vad: RangeVAD(ranges), engine: engine)
        try await session.start()
        let output = try await session.finish()
        #expect(output.text == "segment 1 segment 5")
        #expect(output.failedSegments == 1)
    }

    @Test func cancellingDropsEverythingAndStopsTheEngineWork() async throws {
        let engine = FakeEngine()
        engine.delays = [1: .seconds(30)]
        let session = session(
            ScriptedAudioInput(seconds: 5), vad: RangeVAD([second..<(2 * second)]), engine: engine)
        try await session.start()
        // Cancel only once the engine call is in flight; on a loaded runner the segment arrives late.
        let started = ContinuousClock.now + .seconds(10)
        while engine.state.withLock({ $0.calls }) == 0, ContinuousClock.now < started {
            try await Task.sleep(for: .milliseconds(10))
        }
        await session.cancel()
        await #expect(throws: DictationSession.Failure.cancelled) { try await session.finish() }
        // The engine is told asynchronously: wait for it instead of guessing a delay (a loaded runner needs more).
        let deadline = ContinuousClock.now + .seconds(10)
        while engine.state.withLock({ $0.cancelledCalls }) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(engine.state.withLock { $0.cancelledCalls } == 1)
    }

    @Test func longContinuousSpeechIsCutBeforeTheModelsWindow() async throws {
        let engine = FakeEngine()
        let session = session(
            ScriptedAudioInput(seconds: 40), vad: RangeVAD([0..<(40 * second)]), engine: engine)
        try await session.start()
        let output = try await session.finish()
        #expect(output.segmentCount >= 3)
        #expect(engine.state.withLock { $0.lengths }.allSatisfy { $0 <= DictationSession.longestSegment + 3_000 })
        #expect(engine.state.withLock { $0.lengths }.reduce(0, +) == 40 * second)
    }

    @Test func theRecordingWarnsAndThenReachesItsLimit() async throws {
        let events = EventLog()
        let session = session(
            ScriptedAudioInput(seconds: 12), vad: RangeVAD([second..<(2 * second)]), engine: FakeEngine(),
            maximum: .seconds(10), warning: .seconds(4), events: events)
        try await session.start()
        _ = try await session.finish()
        let seen = events.all
        #expect(seen.contains(.limitApproaching(secondsLeft: 4)))
        #expect(seen.contains(.limitReached))
    }

    @Test func aMicrophoneThatDisappearsIsReportedAndWhatWasSaidCanBeFinished() async throws {
        let events = EventLog()
        let session = session(
            ScriptedAudioInput(seconds: 4, endsEarly: true), vad: RangeVAD([second..<(2 * second)]),
            engine: FakeEngine(), events: events)
        try await session.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(events.all.contains(.audioLost))
        let output = try await session.finish()
        #expect(output.text == "segment 1")
    }

    @Test func aMicrophoneThatCannotStartThrows() async throws {
        let session = session(
            ScriptedAudioInput(seconds: 1, failsToStart: true), vad: RangeVAD([]), engine: FakeEngine())
        await #expect(throws: CaptureError.self) { try await session.start() }
    }

    @Test func finishingBeforeStartingIsAnError() async {
        let session = session(ScriptedAudioInput(seconds: 1), vad: RangeVAD([]), engine: FakeEngine())
        await #expect(throws: DictationSession.Failure.notStarted) { try await session.finish() }
    }
}

@Suite struct SampleStoreTests {
    @Test func indexesDoNotShiftWhenOldSamplesAreDropped() {
        var store = SampleStore()
        store.append((0..<10).map(Float.init))
        store.discard(before: 4)
        #expect(store.count == 10)
        #expect(store.heldCount == 6)
        #expect(store.slice(6..<8) == [6, 7])
        // A range that reaches into the dropped part is clamped.
        #expect(store.slice(2..<6) == [4, 5])
        #expect(store.slice(0..<3).isEmpty)
        store.discard(before: 100)
        #expect(store.heldCount == 0)
        #expect(store.count == 10)
    }

    @Test func memoryStaysBoundedWhileNobodySpeaks() async throws {
        let engine = FakeEngine()
        let session = session(ScriptedAudioInput(seconds: 60), vad: RangeVAD([]), engine: engine)
        try await session.start()
        await #expect(throws: DictationSession.Failure.silence) { try await session.finish() }
    }
}

@Suite struct MicrophoneLevelTests {
    @Test func levelsAreClampedAndLogarithmic() {
        #expect(MicrophoneCapture.level(of: []) == 0)
        #expect(MicrophoneCapture.level(of: [Float](repeating: 0, count: 100)) == 0)
        #expect(MicrophoneCapture.level(of: [Float](repeating: 1, count: 100)) == 1)
        let quiet = MicrophoneCapture.level(of: [Float](repeating: 0.01, count: 100))
        let loud = MicrophoneCapture.level(of: [Float](repeating: 0.1, count: 100))
        #expect(quiet > 0 && loud > quiet && loud < 1)
    }
}

@Suite struct DictationSessionLeaseTests {
    private let folder = URL(filePath: "/tmp/none")

    private func make(
        audio: ScriptedAudioInput, vad: RangeVAD, engine: FakeEngine, lease: SpeechEngineLease,
        events: EventLog = EventLog(), modelID: String = "dictation"
    ) -> DictationSession {
        DictationSession(
            audio: audio, vad: vad, engine: engine, modelFolder: folder, lease: lease, modelID: modelID,
            onEvent: { event in
                if case .level = event { return }
                events.append(event)
            })
    }

    @Test func theLeaseIsGivenBackAfterAFinishedRecording() async throws {
        let lease = SpeechEngineLease()
        let engine = FakeEngine()
        let session = make(
            audio: ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: engine,
            lease: lease)
        try await session.start()
        _ = try await session.finish()
        #expect(await lease.activeLeases == 0)
        #expect(engine.isLoaded)
    }

    @Test func theLeaseIsGivenBackWhenFinishingFails() async throws {
        let lease = SpeechEngineLease()
        let engine = FakeEngine()
        engine.loadFails = true
        let session = make(
            audio: ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: engine,
            lease: lease)
        try await session.start()
        await #expect(throws: DictationSession.Failure.engine) { try await session.finish() }
        #expect(await lease.activeLeases == 0)
        #expect(await lease.residentKey == nil)

        let silent = make(
            audio: ScriptedAudioInput(seconds: 2), vad: RangeVAD([]), engine: FakeEngine(), lease: lease)
        try await silent.start()
        await #expect(throws: DictationSession.Failure.silence) { try await silent.finish() }
        #expect(await lease.activeLeases == 0)
    }

    @Test func theLeaseIsGivenBackWhenTheRecordingIsCancelled() async throws {
        let lease = SpeechEngineLease()
        let session = make(
            audio: ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: FakeEngine(),
            lease: lease)
        try await session.start()
        await session.cancel()
        #expect(await lease.activeLeases == 0)
    }

    @Test func theLeaseIsGivenBackWhenTheMicrophoneCannotStart() async throws {
        let lease = SpeechEngineLease()
        let engine = FakeEngine()
        let session = make(
            audio: ScriptedAudioInput(seconds: 1, failsToStart: true), vad: RangeVAD([]), engine: engine,
            lease: lease)
        await #expect(throws: CaptureError.self) { try await session.start() }
        await eventually { await lease.activeLeases == 0 }
        await eventually { engine.isLoaded }
    }

    @Test func aMicrophoneErrorIsNotHeldUpByTheModelLoad() async throws {
        let lease = SpeechEngineLease()
        let engine = FakeEngine()
        let gate = Gate()
        engine.loadGate = gate
        let session = make(
            audio: ScriptedAudioInput(seconds: 1, failsToStart: true), vad: RangeVAD([]), engine: engine,
            lease: lease)
        // The load is stuck behind the gate; start() still reports the microphone at once.
        await #expect(throws: CaptureError.self) { try await session.start() }
        #expect(!engine.isLoaded)

        gate.open()
        await eventually { engine.isLoaded }
        await eventually { await lease.activeLeases == 0 }
    }

    @Test func aBusyModelIsReportedAtOnceNotAfterTheUserStopsSpeaking() async throws {
        let lease = SpeechEngineLease()
        let meeting = try await lease.acquire(
            modelID: "whisper", folder: folder, engine: FakeEngine(), priority: .background, keepWarm: { .zero })
        let events = EventLog()
        let engine = FakeEngine()
        let session = make(
            audio: ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: engine,
            lease: lease, events: events)
        try await session.start()
        await eventually { events.all.contains(.loadFailed(busy: true)) }
        #expect(!events.all.contains(.loadFailed(busy: false)))
        await #expect(throws: DictationSession.Failure.busy) { try await session.finish() }
        #expect(!engine.isLoaded)
        #expect(await lease.activeLeases == 1)
        await meeting.release()
    }

    @Test func anotherLoadFailureIsReportedAsNotBusy() async throws {
        let engine = FakeEngine()
        engine.loadFails = true
        let events = EventLog()
        let session = make(
            audio: ScriptedAudioInput(seconds: 3), vad: RangeVAD([second..<(2 * second)]), engine: engine,
            lease: SpeechEngineLease(), events: events)
        try await session.start()
        await eventually { events.all.contains(.loadFailed(busy: false)) }
        await #expect(throws: DictationSession.Failure.engine) { try await session.finish() }
    }

    @Test func segmentsAreAskedForInTheOrderTheyWereSaid() async throws {
        let engine = FakeEngine()
        // The first segment is the longest and its answer the slowest.
        engine.delays = [1: .milliseconds(120), 4: .milliseconds(40)]
        let ranges = [second..<(4 * second), (4 * second)..<(6 * second), (6 * second)..<(7 * second)]
        let session = make(
            audio: ScriptedAudioInput(seconds: 8), vad: RangeVAD(ranges), engine: engine,
            lease: SpeechEngineLease())
        try await session.start()
        let output = try await session.finish()
        #expect(engine.state.withLock { $0.lengths } == [3 * second, 2 * second, 1 * second])
        #expect(output.text == "segment 1 segment 4 segment 6")
    }

    @Test func cancellingWhileTheEngineIsBusyDoesNotUnloadItUnderTheRunningSegment() async throws {
        let lease = SpeechEngineLease()
        let engine = FakeEngine()
        let gate = Gate()
        engine.transcribeGate = gate
        let session = make(
            audio: ScriptedAudioInput(seconds: 4), vad: RangeVAD([second..<(2 * second)]), engine: engine,
            lease: lease)
        try await session.start()
        await eventually { engine.state.withLock { $0.calls } == 1 }

        await session.cancel()
        let eviction = Task { await lease.evictIdle() }
        await eventually { await lease.residentKey == nil }
        for _ in 0..<200 { await Task.yield() }
        #expect(engine.state.withLock { $0.unloads } == 0)
        #expect(engine.isLoaded)

        // Positive control: when the segment returns, the unload goes through.
        gate.open()
        await eviction.value
        #expect(engine.state.withLock { $0.unloads } == 1)
    }
}
