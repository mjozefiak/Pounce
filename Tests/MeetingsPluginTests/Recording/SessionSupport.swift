import Foundation
import GRDB
import LintelSpeech
import Synchronization
import Testing
import os

@testable import MeetingsPlugin

let rate = AudioFormat.sampleRate

/// An `AudioInput` the test feeds by hand. Nothing real is ever captured.
final class ControlledInput: AudioInput {
    private struct State {
        var continuation: AsyncStream<[Float]>.Continuation?
        var starts = 0
        var stops = 0
        var failStart = false
        var endOnStart = false
    }

    private let state = Mutex(State())

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }

    init(failStart: Bool = false, endOnStart: Bool = false) {
        state.withLock {
            $0.failStart = failStart
            $0.endOnStart = endOnStart
        }
    }

    func setFailStart(_ fail: Bool) { state.withLock { $0.failStart = fail } }

    struct StartFailure: Error {}

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        if state.withLock({ $0.failStart }) { throw StartFailure() }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        state.withLock {
            $0.continuation = continuation
            $0.starts += 1
        }
        if state.withLock({ $0.endOnStart }) { continuation.finish() }
        return stream
    }

    func stop() async {
        let continuation = state.withLock { state -> AsyncStream<[Float]>.Continuation? in
            state.stops += 1
            return state.continuation
        }
        continuation?.finish()
    }

    /// Delivers samples in chunks of 0.1 s.
    func push(_ samples: [Float]) {
        guard let continuation = state.withLock({ $0.continuation }) else { return }
        var index = 0
        while index < samples.count {
            continuation.yield(Array(samples[index..<min(index + rate / 10, samples.count)]))
            index += rate / 10
        }
    }

    /// The device went away.
    func end() { state.withLock { $0.continuation }?.finish() }
}

/// An input whose `start` waits at a gate, so a test can act while the session is still starting.
final class SlowStartInput: AudioInput {
    let inner = ControlledInput()
    let gate = Gate()
    let entered = Signal()
    private let count = Mutex(0)

    init() { gate.close() }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        count.withLock { $0 += 1 }
        entered.poke()
        await gate.pass()
        return try await inner.start(onLevel: onLevel)
    }

    func stop() async { await inner.stop() }
    var isEntered: Bool { count.withLock { $0 } > 0 }
}

/// Wakes tasks that wait for a condition the test cannot observe through events. Whoever changes the state
/// calls `poke()`. The timeout is only a safety net against a hung test.
final class Signal: Sendable {
    private struct Waiter {
        let id: Int
        let predicate: @Sendable () -> Bool
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let state = Mutex((next: 0, waiters: [Waiter]()))

    func poke() {
        let ready = state.withLock { state -> [Waiter] in
            let ready = state.waiters.filter { $0.predicate() }
            state.waiters.removeAll { waiter in ready.contains { $0.id == waiter.id } }
            return ready
        }
        for waiter in ready { waiter.continuation.resume(returning: true) }
    }

    func wait(timeout: Duration = .seconds(20), until predicate: @escaping @Sendable () -> Bool) async -> Bool {
        if predicate() { return true }
        let id = state.withLock { state -> Int in
            state.next += 1
            return state.next
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let immediate = state.withLock { state -> Bool in
                if predicate() { return true }
                state.waiters.append(Waiter(id: id, predicate: predicate, continuation: continuation))
                return false
            }
            if immediate {
                continuation.resume(returning: true)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                let expired = state.withLock { state -> Waiter? in
                    guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                    return state.waiters.remove(at: index)
                }
                expired?.continuation.resume(returning: false)
            }
        }
    }
}

/// Lets the test run the session's wall-clock heartbeat by hand: `tick` moves the clock and wakes one wait.
final class TestClock: Sendable {
    private struct State {
        var date = Date(timeIntervalSince1970: 1_000_000)
        var pending = 0
        var waiter: (id: Int, continuation: CheckedContinuation<Void, Error>)?
        var next = 0
    }

    private let state = Mutex(State())

    var now: @Sendable () -> Date { { self.state.withLock { $0.date } } }
    var sleeper: @Sendable (Duration) async throws -> Void { { _ in try await self.sleepOnce() } }

    func tick(advancing seconds: Double) {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
            state.date = state.date.addingTimeInterval(seconds)
            guard let waiter = state.waiter else {
                state.pending += 1
                return nil
            }
            state.waiter = nil
            return waiter.continuation
        }
        waiter?.resume()
    }

    private func sleepOnce() async throws {
        let id = state.withLock { state -> Int in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let result = state.withLock { state -> Bool? in
                    if Task.isCancelled { return false }
                    if state.pending > 0 {
                        state.pending -= 1
                        return true
                    }
                    state.waiter = (id, continuation)
                    return nil
                }
                switch result {
                case true: continuation.resume()
                case false: continuation.resume(throwing: CancellationError())
                default: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Error>? in
                guard let waiter = state.waiter, waiter.id == id else { return nil }
                state.waiter = nil
                return waiter.continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// A voice activity detector that knows where the speech is (sample ranges) and reports it as the samples pass.
final class ScriptedVAD: VoiceActivityDetector {
    private let spans: [Range<Int>]
    private let position = Mutex(0)

    init(_ spans: [Range<Int>]) { self.spans = spans }

    func process(_ samples: [Float]) async throws -> [VADEvent] {
        let (from, to) = position.withLock { position -> (Int, Int) in
            defer { position += samples.count }
            return (position, position + samples.count)
        }
        var events: [VADEvent] = []
        for span in spans {
            if (from..<to).contains(span.lowerBound) {
                events.append(VADEvent(kind: .speechStart, sampleIndex: span.lowerBound))
            }
            if (from..<to).contains(span.upperBound) {
                events.append(VADEvent(kind: .speechEnd, sampleIndex: span.upperBound))
            }
        }
        return events
    }
}

/// One track's audio: silence with utterances. An utterance is a constant level (`code / 100`), so the fake
/// engine can tell which one it was given from the first sample.
struct TrackScript {
    private(set) var samples: [Float] = []
    private(set) var spans: [Range<Int>] = []

    mutating func silence(_ seconds: Double) {
        samples += [Float](repeating: 0, count: Int(seconds * Double(rate)))
    }

    /// Speech for `seconds`; `closed: false` leaves the voice activity detector without an end event.
    mutating func say(_ code: Int, seconds: Double, closed: Bool = true) {
        let start = samples.count
        samples += [Float](repeating: Float(code) / 100, count: Int(seconds * Double(rate)))
        spans.append(start..<(closed ? samples.count : samples.count + 10_000_000))
    }

    var vad: ScriptedVAD { ScriptedVAD(spans) }
}

/// A gate the fake engine waits at while closed.
final class Gate: Sendable {
    private struct State {
        var open = true
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func close() { state.withLock { $0.open = false } }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func pass() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }
}

/// A speech engine without a model: the text is looked up from the utterance's level.
final class ScriptedEngine: SpeechEngine {
    struct Failure: Error {}

    private struct State {
        var loaded = false
        var loads = 0
        var unloads = 0
        var texts: [Int: String] = [:]
        var failures: [Int: Int] = [:]
        var heard: [Int] = []
        var entered = 0
    }

    private let state = Mutex(State())
    let gate = Gate()

    init(texts: [Int: String]) { state.withLock { $0.texts = texts } }

    var loads: Int { state.withLock { $0.loads } }
    var unloads: Int { state.withLock { $0.unloads } }
    var heard: [Int] { state.withLock { $0.heard } }
    /// The next `times` transcriptions of this utterance throw (all of them by default).
    func fail(_ code: Int, times: Int = .max) { state.withLock { $0.failures[code] = times } }
    let unloaded = Signal()
    let transcribing = Signal()
    var entered: Int { state.withLock { $0.entered } }

    var isLoaded: Bool { state.withLock { $0.loaded } }

    func load(modelFolder: URL) async throws {
        state.withLock {
            $0.loaded = true
            $0.loads += 1
        }
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        state.withLock { $0.entered += 1 }
        transcribing.poke()
        await gate.pass()
        let code = Int(((samples.first ?? 0) * 100).rounded())
        let result: String? = state.withLock { state in
            state.heard.append(code)
            if let left = state.failures[code], left > 0 {
                if left != .max { state.failures[code] = left - 1 }
                return nil
            }
            return state.texts[code] ?? "?\(code)"
        }
        guard let result else { throw Failure() }
        return TranscriptSegment(text: result)
    }

    func unload() async {
        state.withLock {
            $0.loaded = false
            $0.unloads += 1
        }
        unloaded.poke()
    }
}

/// Records every hold and release.
final class RecordingSleepAssertion: SleepAssertion {
    private let state = Mutex((holds: 0, releases: 0, held: false))
    var holds: Int { state.withLock { $0.holds } }
    var releases: Int { state.withLock { $0.releases } }
    var isHeld: Bool { state.withLock { $0.held } }

    func hold(reason: String) {
        state.withLock {
            guard !$0.held else { return }
            $0.held = true
            $0.holds += 1
        }
    }

    func release() {
        state.withLock {
            guard $0.held else { return }
            $0.held = false
            $0.releases += 1
        }
    }
}

/// The events of a session, collected as they come.
final class SessionEventLog: Sendable {
    private final class Box: Sendable {
        let items = Mutex<[MeetingSessionEvent]>([])
    }

    private let box = Box()
    private let signal = Signal()
    private let task: Task<Void, Never>

    init(_ session: MeetingSession) {
        let stream = session.events
        let box = box
        let signal = signal
        task = Task {
            for await event in stream {
                box.items.withLock { $0.append(event) }
                signal.poke()
            }
        }
    }

    /// Waits until an event satisfies `predicate` (events arrive from other tasks).
    func wait(_ predicate: @escaping @Sendable (MeetingSessionEvent) -> Bool) async -> Bool {
        let box = box
        return await signal.wait { box.items.withLock { $0.contains(where: predicate) } }
    }

    var all: [MeetingSessionEvent] { box.items.withLock { $0 } }

    func contains(_ predicate: (MeetingSessionEvent) -> Bool) -> Bool { all.contains(where: predicate) }

    /// The stream ends with the session; wait for the collector.
    func drain() async { await task.value }
}

/// Yields to other tasks until `condition` holds (actor state that has no event).
func spin(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

struct SegmentRow: Equatable {
    let channel: String
    let startMs: Int
    let endMs: Int
    let text: String
    let speakerID: Int64?
}

/// A session wired to fakes: a temporary folder, an in-memory keychain's keys, a private lease.
struct SessionRig {
    let directory: TemporaryDirectory
    let store: MeetingsStore
    let keys: MeetingKeys
    let spool: SpoolStorage
    let engine: ScriptedEngine
    let lease: SpeechEngineLease
    let sleepAssertion = RecordingSleepAssertion()
    let gate = MeetingSessionGate()
    let mic = ControlledInput()
    let system = ControlledInput()

    var warmSleeps: WarmSleeps

    final class WarmSleeps: Sendable {
        private let durations = Mutex<[Duration]>([])
        private let gate = Gate()
        var recorded: [Duration] { durations.withLock { $0 } }
        let slept = Signal()
        init() { gate.close() }
        func sleep(_ duration: Duration) async throws {
            durations.withLock { $0.append(duration) }
            slept.poke()
            await gate.pass()
        }
        func expire() { gate.open() }
    }

    init(texts: [Int: String] = [:]) throws {
        directory = try TemporaryDirectory()
        keys = try testKeys()
        store = try MeetingsStore.open(in: directory.url.appending(path: "meetings"), keys: keys)
        spool = SpoolStorage(pluginDirectory: directory.url.appending(path: "meetings"))
        engine = ScriptedEngine(texts: texts)
        warmSleeps = WarmSleeps()
        let sleeps = warmSleeps
        lease = SpeechEngineLease(sleep: { try await sleeps.sleep($0) })
    }

    func session(
        mic micScript: TrackScript, system systemScript: TrackScript?, limits: MeetingSessionLimits? = nil,
        freeSpace: @escaping SpoolWriter.FreeSpaceProvider = { _ in Int64.max }, systemInput: ControlledInput? = nil,
        micInput: ControlledInput? = nil, gate: MeetingSessionGate? = nil, uuid: UUID = UUID(),
        modelID: String = "test-model", lease: SpeechEngineLease? = nil, engine: (any SpeechEngine)? = nil,
        withSystem: Bool = true, clock: TestClock? = nil, micAudio: (any AudioInput)? = nil,
        beforeReady: (@Sendable (Int64, UUID) async -> Void)? = nil, sourceBundleID: String? = nil
    ) -> MeetingSession {
        var nowFn: @Sendable () -> Date = { Date() }
        var sleepFn: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        if let clock {
            nowFn = clock.now
            sleepFn = clock.sleeper
        }
        let vads = Mutex<[ScriptedVAD]>([micScript.vad] + (systemScript.map { [$0.vad] } ?? []))
        return MeetingSession(
            store: store, keys: keys, spool: spool, mic: micAudio ?? micInput ?? mic,
            system: withSystem ? (systemInput ?? system) : nil,
            makeVAD: { vads.withLock { $0.isEmpty ? ScriptedVAD([]) : $0.removeFirst() } },
            engine: engine ?? self.engine, modelID: modelID, modelFolder: directory.url.appending(path: "model"),
            lease: lease ?? self.lease, keepWarm: { .seconds(321) }, sleepAssertion: sleepAssertion,
            gate: gate ?? self.gate, limits: limits ?? shortLimits, freeSpace: freeSpace, uuid: uuid,
            now: nowFn, sleep: sleepFn,
            beforeReady: beforeReady, sourceBundleID: sourceBundleID)
    }

    var shortLimits: MeetingSessionLimits {
        var limits = MeetingSessionLimits()
        limits.discardBelow = .seconds(15)
        return limits
    }

    func rows(_ meetingID: Int64) throws -> [SegmentRow] {
        try store.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT channel, start_ms, end_ms, text, speaker_id FROM meeting_segment
                    WHERE meeting_id = ? ORDER BY start_ms, id
                    """, arguments: [meetingID]
            ).map {
                SegmentRow(
                    channel: $0["channel"], startMs: $0["start_ms"], endMs: $0["end_ms"], text: $0["text"],
                    speakerID: $0["speaker_id"])
            }
        }
    }
}
