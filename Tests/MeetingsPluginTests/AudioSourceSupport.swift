import Foundation
import Synchronization

@testable import MeetingsPlugin

/// A clock the test moves by hand; ticks are nanoseconds.
final class FakeClock: HostClock {
    private let ticks: Mutex<UInt64>

    init(_ start: UInt64 = 0) { ticks = Mutex(start) }

    func now() -> UInt64 { ticks.withLock { $0 } }
    func set(_ value: UInt64) { ticks.withLock { $0 = value } }
}

/// A scripted Core Audio: no tap is ever created. Tests push buffers into the current tap by hand.
final class FakeBackend: ProcessTapBackend {
    struct State {
        var sinks: [@Sendable (TapBuffer) -> Void] = []
        var stopped: [Bool] = []
        var excluding: [Bool] = []
        var failures: [SystemAudioError] = []
        var changeHandler: (@Sendable () -> Void)?
        var observationCancelled = false
        var observations = 0
        var fireChangeWhileObserving = false
        var observeFailure: SystemAudioError?
    }

    let state = Mutex(State())

    var tapCount: Int { state.withLock { $0.sinks.count } }
    var excludingFlags: [Bool] { state.withLock { $0.excluding } }
    var stoppedFlags: [Bool] { state.withLock { $0.stopped } }
    var observationCancelled: Bool { state.withLock { $0.observationCancelled } }
    /// How many output observations were ever installed.
    var observationCount: Int { state.withLock { $0.observations } }

    /// The device change fires inside `observeOutputDeviceChanges`, the order in which a real change can race
    /// the end of `start`.
    func fireChangeWhileObserving() { state.withLock { $0.fireChangeWhileObserving = true } }
    func failObservation(_ error: SystemAudioError) { state.withLock { $0.observeFailure = error } }

    /// The next `startTap` calls throw these, in order.
    func failNext(_ errors: [SystemAudioError]) { state.withLock { $0.failures = errors } }

    func startTap(
        excludingOwnProcess: Bool, onBuffer: @escaping @Sendable (TapBuffer) -> Void
    ) throws(SystemAudioError) -> any ProcessTapSession {
        let index: Int? = state.withLock { state in
            if !state.failures.isEmpty { return nil }
            state.sinks.append(onBuffer)
            state.stopped.append(false)
            state.excluding.append(excludingOwnProcess)
            return state.sinks.count - 1
        }
        if index == nil {
            throw state.withLock { $0.failures.removeFirst() }
        }
        return FakeSession(backend: self, index: index ?? 0)
    }

    func observeOutputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) throws(SystemAudioError) -> any OutputChangeObservation {
        let (failure, fire) = state.withLock { state -> (SystemAudioError?, Bool) in
            if state.observeFailure == nil {
                state.changeHandler = handler
                state.observations += 1
            }
            return (state.observeFailure, state.fireChangeWhileObserving)
        }
        if let failure { throw failure }
        if fire { handler() }
        return FakeObservation(backend: self)
    }

    /// Delivers a buffer through tap number `tap` (0 is the first one created).
    func deliver(_ buffer: TapBuffer, tap: Int? = nil) {
        let sink = state.withLock { state in state.sinks[tap ?? state.sinks.count - 1] }
        sink(buffer)
    }

    func changeOutputDevice() {
        let handler = state.withLock { $0.changeHandler }
        handler?()
    }

    private struct FakeSession: ProcessTapSession {
        let backend: FakeBackend
        let index: Int
        func stop() { backend.state.withLock { $0.stopped[index] = true } }
    }

    private struct FakeObservation: OutputChangeObservation {
        let backend: FakeBackend
        func cancel() { backend.state.withLock { $0.observationCancelled = true } }
    }
}

/// A tone player that records the request and can feed the fake tap while "playing".
final class FakeTonePlayer: TonePlayer {
    let played = Mutex<[TimeInterval]>([])
    let whilePlaying: @Sendable () -> Void
    let failure: Bool
    let error: (any Error)?

    init(failure: Bool = false, error: (any Error)? = nil, whilePlaying: @escaping @Sendable () -> Void = {}) {
        self.failure = failure
        self.error = error
        self.whilePlaying = whilePlaying
    }

    func play(duration: TimeInterval) async throws {
        played.withLock { $0.append(duration) }
        if let error { throw error }
        if failure { throw SystemAudioError.unsupportedFormat }
        whilePlaying()
    }
}

enum Synth {
    /// Interleaved stereo sine, `frames` frames at `rate`, the same signal in both channels.
    static func sine(
        frequency: Double, rate: Double, frames: Int, channels: Int = 2, startFrame: Int = 0, amplitude: Float = 0.5
    ) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(startFrame + frame) / rate))
            for _ in 0..<channels { out.append(value) }
        }
        return out
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    static func zeroCrossings(_ samples: [Float]) -> Int {
        zip(samples, samples.dropFirst()).filter { ($0 < 0) != ($1 < 0) }.count
    }

    /// A 16 kHz mono WAV with 16-bit samples.
    static func wav16(_ samples: [Float], rate: UInt32 = 16_000, channels: UInt16 = 1) -> Data {
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let body = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        put32(36 + body)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        put32(16)
        put16(1)
        put16(channels)
        put32(rate)
        put32(rate * UInt32(channels) * 2)
        put16(channels * 2)
        put16(16)
        data.append(contentsOf: Array("data".utf8))
        put32(body)
        for sample in samples { put16(UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767))) }
        return data
    }
}

/// Collects a stream in the background.
final class StreamCollector: Sendable {
    private final class Box: Sendable {
        let chunks = Mutex<[[Float]]>([])
    }

    private let box = Box()
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<[Float]>) {
        let box = self.box
        task = Task {
            for await chunk in stream { box.chunks.withLock { $0.append(chunk) } }
        }
    }

    /// Waits for the stream to end and returns everything.
    func finished() async -> [Float] {
        await task.value
        return current()
    }

    /// What has arrived so far (the consumer task may lag a moment behind a `deliver`).
    func current() -> [Float] { box.chunks.withLock { $0.flatMap { $0 } } }
}

/// Events the source reported, appended from any thread.
final class EventLog: Sendable {
    private let storage = Mutex<[SystemAudioEvent]>([])
    var value: [SystemAudioEvent] { storage.withLock { $0 } }
    func append(_ event: SystemAudioEvent) { storage.withLock { $0.append(event) } }
}

struct WaitTimeout: Error {}

/// Polls until `condition` holds (background tasks of the source under test), failing after two seconds.
func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<400 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw WaitTimeout()
}

/// A tone player that never returns until released, and ignores cancellation like a stuck audio engine.
final class HangingTonePlayer: TonePlayer {
    private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

    var isWaiting: Bool { continuation.withLock { $0 != nil } }

    func play(duration: TimeInterval) async throws {
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            continuation.withLock { $0 = waiting }
        }
    }

    func release() {
        let waiting = continuation.withLock { value -> CheckedContinuation<Void, Never>? in
            defer { value = nil }
            return value
        }
        waiting?.resume()
    }
}
