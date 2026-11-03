import Foundation
import Synchronization

/// What a `background` transcription request came back with.
public enum SpeechOutcome: Equatable, Sendable {
    case transcript(TranscriptSegment)
    /// The background queue already holds a minute of unfinished audio: the caller keeps this audio in its
    /// spool and asks again later.
    case spool
}

/// The one place that loads and unloads the speech engine and decides who may use it (spec: Dzierżawy modeli).
/// Dictation and meetings share it: the same `(model id, folder)` key shares one copy in memory, a different
/// key waits for the lease to be released (`ModelLeaseError.busy` while it is in use, replaced at once when it
/// only sits warm), and the keep-warm time counts from the release of the last lease.
///
/// Transcriptions go through one queue: `interactive` before `background`, one at a time. A transcription that
/// has started is not interrupted (Core ML cannot be cancelled), so the wait of a dictation is at most one
/// segment of someone else's.
public final class SpeechEngineLease: Sendable {
    public static let shared = SpeechEngineLease()

    public struct Key: Hashable, Sendable {
        public let modelID: String
        public let folder: URL

        public init(modelID: String, folder: URL) {
            self.modelID = modelID
            self.folder = folder.standardizedFileURL
        }
    }

    /// The most unfinished audio the `background` queue holds, in samples (60 s).
    public static let backgroundLimit = 60 * AudioFormat.sampleRate

    private let residency: Residency<Key, any SpeechEngine>
    private let turnstile = Turnstile()
    private let pendingBackground = Mutex(0)

    /// - Parameter sleep: waits out the keep-warm time; tests replace it.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        residency = Residency(
            ops: .init(isLoaded: { await $0.isLoaded }, unload: { await $0.unload() }), sleep: sleep)
    }

    /// Takes a lease on the engine for `modelID` in `folder`. When that key is resident, its engine is shared and
    /// `engine` is ignored; otherwise `engine` is loaded (after an idle resident one is unloaded).
    /// - Parameters:
    ///   - onLoading: called right before a load that is actually needed.
    ///   - keepWarm: how long the engine stays after the last lease is released.
    public func acquire(
        modelID: String, folder: URL, engine: any SpeechEngine, priority: LeasePriority,
        keepWarm: @escaping @Sendable () -> Duration, onLoading: @escaping @Sendable () -> Void = {}
    ) async throws -> SpeechLease {
        let key = Key(modelID: modelID, folder: folder)
        let shared = try await residency.acquire(key: key, model: engine) { engine in
            onLoading()
            try await engine.load(modelFolder: key.folder)
        }
        return SpeechLease(owner: self, key: key, engine: shared, priority: priority, keepWarm: keepWarm)
    }

    /// Unloads the engine now when no lease is active (plugin switched off). Returns when it is unloaded.
    public func evictIdle() async {
        await residency.evictIdle()
    }

    /// The key that is in memory, for tests and diagnostics.
    public var residentKey: Key? {
        get async { await residency.residentKey }
    }

    public var activeLeases: Int {
        get async { await residency.activeLeases }
    }

    /// Transcriptions waiting for their turn.
    var queued: Int { turnstile.waiting }

    fileprivate func release(_ key: Key, keepWarm: Duration) async {
        await residency.release(key: key, keepWarm: keepWarm)
    }

    fileprivate func transcribe(
        _ samples: [Float], with engine: any SpeechEngine, priority: LeasePriority
    ) async throws -> SpeechOutcome {
        if priority == .background {
            let accepted = pendingBackground.withLock { pending -> Bool in
                // An empty queue always takes a segment, so one long piece cannot be refused forever.
                guard pending == 0 || pending + samples.count <= Self.backgroundLimit else { return false }
                pending += samples.count
                return true
            }
            guard accepted else { return .spool }
        }
        defer {
            if priority == .background { pendingBackground.withLock { $0 -= samples.count } }
        }
        try await turnstile.enter(priority)
        defer { turnstile.leave() }
        return .transcript(try await engine.transcribe(samples))
    }
}

/// A claim on the engine. Release it when the recording or the meeting ends.
public final class SpeechLease: Sendable {
    public let key: SpeechEngineLease.Key
    public let priority: LeasePriority
    private let owner: SpeechEngineLease
    private let engine: any SpeechEngine
    private let keepWarm: @Sendable () -> Duration
    private let released = Mutex(false)

    fileprivate init(
        owner: SpeechEngineLease, key: SpeechEngineLease.Key, engine: any SpeechEngine, priority: LeasePriority,
        keepWarm: @escaping @Sendable () -> Duration
    ) {
        self.owner = owner
        self.key = key
        self.engine = engine
        self.priority = priority
        self.keepWarm = keepWarm
    }

    /// Transcribes one segment in turn. A `background` lease may get `.spool` back.
    public func transcribe(_ samples: [Float]) async throws -> SpeechOutcome {
        guard !released.withLock({ $0 }) else { throw ModelLeaseError.released }
        return try await owner.transcribe(samples, with: engine, priority: priority)
    }

    /// Gives the lease back (once); the engine unloads after the keep-warm time unless someone takes a lease.
    public func release() async {
        let wasReleased = released.withLock { state -> Bool in
            let was = state
            state = true
            return was
        }
        guard !wasReleased else { return }
        await owner.release(key, keepWarm: keepWarm())
    }
}
