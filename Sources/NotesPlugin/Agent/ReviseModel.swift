import Foundation
import LintelSpeech

/// The notes model's lease, as the revise run sees it: the part of `LLMLease` it needs, so tests script `busy` and
/// `yielded` without a model.
protocol ReviseModelLeasing: Sendable {
    /// Takes the lease. Throws `ModelLeaseError.busy` while another model file (or dictation's grace period) holds
    /// the memory; any other error means the model cannot be had.
    func acquire() async throws -> any ReviseModelHandle
}

protocol ReviseModelHandle: Sendable {
    /// One completion. Throws `ModelLeaseError.yielded` when dictation took the model over (the lease is gone), and
    /// `CancellationError` when the calling task is cancelled (the model stops between two tokens).
    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult
    func release() async
}

/// The model a run uses: its catalog id (recorded in `meta_json`) and its lease.
struct ResolvedReviseModel: Sendable {
    var id: String
    var leasing: any ReviseModelLeasing
}

/// The lease key of the notes model: built exactly as Meetings' `NotesPipeline` builds it (`LLMLease` keys and
/// `isInUse(modelID:)` use the file path, not the catalog id; the context length is the notes' 8192), so when both
/// settings name the same model they share one resident model, and otherwise the second waits on `busy`.
enum ReviseModelKey {
    static let contextLength = 8192

    static func make(modelFile: URL) -> LLMLease.Key {
        LLMLease.Key(modelID: modelFile.path, contextLength: contextLength)
    }
}

/// The real lease: `LLMLease.shared`, `background` priority (dictation always goes first), the same model file.
struct LeasedReviseModel: ReviseModelLeasing {
    let lease: LLMLease
    let runtime: any LLMRuntime
    let modelURL: URL
    let keepWarm: @Sendable () -> Duration

    init(
        lease: LLMLease = .shared,
        runtime: any LLMRuntime = LlamaRuntime(contextLength: ReviseModelKey.contextLength), modelURL: URL,
        keepWarm: @escaping @Sendable () -> Duration = { .seconds(60) }
    ) {
        self.lease = lease
        self.runtime = runtime
        self.modelURL = modelURL
        self.keepWarm = keepWarm
    }

    var key: LLMLease.Key { .init(modelID: modelURL.path, contextLength: runtime.contextLength) }

    func acquire() async throws -> any ReviseModelHandle {
        let handle = try await lease.acquire(
            key: key, runtime: runtime, modelURL: modelURL, priority: .background, keepWarm: keepWarm)
        return LeasedHandle(handle: handle)
    }

    private struct LeasedHandle: ReviseModelHandle {
        let handle: LLMHandle

        func generate(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
            try await handle.generateResult(messages: messages, maxTokens: maxTokens)
        }

        func release() async { await handle.release() }
    }
}

/// A clock as the run reads it: an instant as a duration since an origin, and a sleep, both on the injected clock
/// (`PluginContext.clock`), so every timeout is tested without waiting.
struct RunClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }
}
