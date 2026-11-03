import Foundation
import Synchronization

@testable import PounceSpeech

/// Yields to the other tasks until `condition` holds. Bounded, so a broken test fails instead of hanging; no
/// real time passes.
func until(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<500_000 {
        if await condition() { return }
        await Task.yield()
    }
}

/// A one-shot gate a fake waits on until the test opens it.
final class Latch: Sendable {
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

/// A keep-warm sleeper the test fires by hand.
final class ManualSleeper: Sendable {
    private struct Pending {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var next = 0
        var pending: [Pending] = []
    }

    private let state = Mutex(State())

    var durations: [Duration] { state.withLock { $0.pending.map(\.duration) } }

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.pending.append(Pending(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let entry = state.withLock { state -> Pending? in
                guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return nil }
                return state.pending.remove(at: index)
            }
            entry?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Ends every sleep that is waiting.
    func fire() {
        let entries = state.withLock { state -> [Pending] in
            defer { state.pending = [] }
            return state.pending
        }
        for entry in entries { entry.continuation.resume() }
    }
}

/// How many models are in memory at once across the fakes of one test.
final class MemoryTracker: Sendable {
    private let state = Mutex((current: 0, peak: 0))
    var peak: Int { state.withLock { $0.peak } }
    var current: Int { state.withLock { $0.current } }

    func loaded() {
        state.withLock {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
        }
    }

    func unloaded() { state.withLock { $0.current -= 1 } }
}

/// A speech engine the test can hold at chosen segments. A segment is identified by its first sample.
final class LeaseEngine: SpeechEngine, @unchecked Sendable {
    struct State {
        var loaded = false
        var loads = 0
        var unloads = 0
        var started: [Int] = []
        var finished: [Int] = []
        var held: [Int: Latch] = [:]
        var failsToLoad = false
    }

    struct LoadFailure: Error {}

    let state = Mutex(State())
    let tracker: MemoryTracker

    init(tracker: MemoryTracker = MemoryTracker()) { self.tracker = tracker }

    var isLoaded: Bool { state.withLock { $0.loaded } }
    var loads: Int { state.withLock { $0.loads } }
    var unloads: Int { state.withLock { $0.unloads } }
    var started: [Int] { state.withLock { $0.started } }
    var finished: [Int] { state.withLock { $0.finished } }

    func hold(_ id: Int) { state.withLock { $0.held[id] = Latch() } }

    func letGo(_ id: Int) {
        let latch = state.withLock { $0.held[id] }
        latch?.open()
    }

    func load(modelFolder: URL) async throws {
        if state.withLock({ $0.failsToLoad }) { throw LoadFailure() }
        state.withLock {
            $0.loaded = true
            $0.loads += 1
        }
        tracker.loaded()
    }

    func unload() async {
        let was = state.withLock { state -> Bool in
            let was = state.loaded
            state.loaded = false
            state.unloads += 1
            return was
        }
        if was { tracker.unloaded() }
    }

    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        let id = Int(samples.first ?? 0)
        let latch = state.withLock { state -> Latch? in
            state.started.append(id)
            return state.held[id]
        }
        await latch?.wait()
        state.withLock { $0.finished.append(id) }
        return TranscriptSegment(text: "segment \(id)")
    }
}

/// `seconds` of audio whose first sample is `id`.
func audio(_ id: Int, seconds: Int = 1) -> [Float] {
    var samples = [Float](repeating: 0, count: seconds * AudioFormat.sampleRate)
    samples[0] = Float(id)
    return samples
}

/// A language model that answers "<label>#<attempt>"; the first attempt of the label "bg" never finishes by
/// itself (it waits until it is cancelled, which is what a decode loop does between two tokens).
final class LeaseLLM: LLMRuntime, @unchecked Sendable {
    struct State {
        var loaded = false
        var loads: [URL] = []
        var unloads = 0
        var log: [String] = []
        var attempts: [String: Int] = [:]
    }

    let state = Mutex(State())
    let contextLength: Int
    let tracker: MemoryTracker

    init(contextLength: Int = 4096, tracker: MemoryTracker = MemoryTracker()) {
        self.contextLength = contextLength
        self.tracker = tracker
    }

    var isLoaded: Bool { state.withLock { $0.loaded } }
    var loads: [URL] { state.withLock { $0.loads } }
    var unloads: Int { state.withLock { $0.unloads } }
    var log: [String] { state.withLock { $0.log } }

    func load(modelAt url: URL) async throws {
        state.withLock {
            $0.loaded = true
            $0.loads.append(url)
        }
        tracker.loaded()
    }

    func unload() async {
        let was = state.withLock { state -> Bool in
            let was = state.loaded
            state.loaded = false
            state.unloads += 1
            return was
        }
        if was { tracker.unloaded() }
    }

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await generateResult(messages: messages, maxTokens: maxTokens).text
    }

    func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        let label = messages.first?.content ?? ""
        let attempt = state.withLock { state -> Int in
            state.attempts[label, default: 0] += 1
            state.log.append("start \(label)")
            return state.attempts[label, default: 0]
        }
        if label == "bg", attempt == 1 {
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                state.withLock { $0.log.append("cancelled \(label)") }
                throw error
            }
        }
        state.withLock { $0.log.append("done \(label)") }
        return GenerationResult(text: "\(label)#\(attempt)", stoppedByTokenLimit: false)
    }
}
