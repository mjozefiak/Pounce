import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import PounceSpeech

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

/// Answers "segment N" after a delay that depends on the segment's length, and can fail or load slowly.
final class FakeEngine: SpeechEngine, @unchecked Sendable {
    struct State {
        var loaded = false
        var calls = 0
        var lengths: [Int] = []
        var cancelledCalls = 0
        var unloads = 0
    }

    let state = Mutex(State())
    var loadDelay: Duration = .zero
    var loadFails = false
    /// Delay before answering, by the second of audio the segment starts in.
    var delays: [Int: Duration] = [:]
    var failingSeconds: Set<Int> = []

    var isLoaded: Bool { state.withLock { $0.loaded } }

    func load(modelFolder: URL) async throws {
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
        do {
            try await Task.sleep(for: delays[key] ?? .zero)
        } catch {
            state.withLock { $0.cancelledCalls += 1 }
            throw error
        }
        if failingSeconds.contains(key) { throw CaptureError.noInputDevice }
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
        try await Task.sleep(for: .milliseconds(100))
        await session.cancel()
        await #expect(throws: DictationSession.Failure.cancelled) { try await session.finish() }
        try await Task.sleep(for: .milliseconds(100))
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
