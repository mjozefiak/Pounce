import Foundation
import Synchronization

/// The language-model twin of `SpeechEngineLease`: key `(model id, context length)` (dictation 4096, notes
/// 8192), at most one model resident, `busy` for another key while a lease is active, the keep-warm time from
/// the last release. Generation goes through one queue, `interactive` first; a `background` generation that is
/// running is cancelled between two tokens when an `interactive` request arrives and starts over after it.
public final class LLMLease: Sendable {
    public static let shared = LLMLease()

    public struct Key: Hashable, Sendable {
        public let modelID: String
        public let contextLength: Int

        public init(modelID: String, contextLength: Int) {
            self.modelID = modelID
            self.contextLength = contextLength
        }
    }

    private let residency: Residency<Key, any LLMRuntime>
    private let turnstile = Turnstile()

    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        residency = Residency(
            ops: .init(isLoaded: { await $0.isLoaded }, unload: { await $0.unload() }), sleep: sleep)
    }

    /// Takes a lease on the model. When `key` is resident its runtime is shared and `runtime` is ignored;
    /// otherwise `runtime` loads `modelURL` (after an idle resident model is unloaded).
    public func acquire(
        key: Key, runtime: any LLMRuntime, modelURL: URL, priority: LeasePriority,
        keepWarm: @escaping @Sendable () -> Duration
    ) async throws -> LLMHandle {
        let shared = try await residency.acquire(key: key, model: runtime) { runtime in
            try await runtime.load(modelAt: modelURL)
        }
        return LLMHandle(owner: self, key: key, runtime: shared, priority: priority, keepWarm: keepWarm)
    }

    /// Unloads the model now when no lease is active. Returns when it is unloaded.
    public func evictIdle() async {
        await residency.evictIdle()
    }

    public var residentKey: Key? {
        get async { await residency.residentKey }
    }

    public var activeLeases: Int {
        get async { await residency.activeLeases }
    }

    /// Generations waiting for their turn.
    var queued: Int { turnstile.waiting }

    fileprivate func release(_ key: Key, keepWarm: Duration) async {
        await residency.release(key: key, keepWarm: keepWarm)
    }

    fileprivate func generate(
        _ runtime: any LLMRuntime, priority: LeasePriority, messages: [ChatMessage], maxTokens: Int
    ) async throws -> GenerationResult {
        while true {
            let preemption = Preemption()
            try await turnstile.enter(priority, preempt: { preemption.fire() })
            let run = Task { try await runtime.generateResult(messages: messages, maxTokens: maxTokens) }
            preemption.attach(run)
            let result = await withTaskCancellationHandler {
                await run.result
            } onCancel: {
                run.cancel()
            }
            turnstile.leave()
            switch result {
            case .success(let value):
                return value
            case .failure(let error):
                // Stopped for an interactive request, not by the caller: wait for the turn again.
                if error is CancellationError, preemption.fired, !Task.isCancelled { continue }
                throw error
            }
        }
    }
}

/// Lets the turnstile cancel a generation that may not have started yet.
private final class Preemption: Sendable {
    private struct State {
        var fired = false
        var task: Task<GenerationResult, any Error>?
    }

    private let state = Mutex(State())

    var fired: Bool { state.withLock { $0.fired } }

    func attach(_ task: Task<GenerationResult, any Error>) {
        let cancelNow = state.withLock { state -> Bool in
            state.task = task
            return state.fired
        }
        if cancelNow { task.cancel() }
    }

    func fire() {
        let task = state.withLock { state -> Task<GenerationResult, any Error>? in
            state.fired = true
            return state.task
        }
        task?.cancel()
    }
}

public final class LLMHandle: Sendable {
    public let key: LLMLease.Key
    public let priority: LeasePriority
    private let owner: LLMLease
    private let runtime: any LLMRuntime
    private let keepWarm: @Sendable () -> Duration
    private let released = Mutex(false)

    fileprivate init(
        owner: LLMLease, key: LLMLease.Key, runtime: any LLMRuntime, priority: LeasePriority,
        keepWarm: @escaping @Sendable () -> Duration
    ) {
        self.owner = owner
        self.key = key
        self.runtime = runtime
        self.priority = priority
        self.keepWarm = keepWarm
    }

    public func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        guard !released.withLock({ $0 }) else { throw ModelLeaseError.released }
        return try await owner.generate(runtime, priority: priority, messages: messages, maxTokens: maxTokens)
    }

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
