import Foundation

/// Keeps a model loaded for a while after its last use and frees it afterwards (spec: `keepWarmMinutes`).
/// The first request after the pause loads it again; `warmUp()` does that ahead of time, when recording starts.
///
/// The residency itself lives in an `LLMLease`: every request takes a lease, so the model is shared with the
/// other users of the process (the same model and context length), a request for another model waits its turn
/// (`ModelLeaseError.busy`), and the keep-warm time runs from the release of the last lease.
public actor KeepWarmRuntime {
    private let runtime: any LLMRuntime
    private let modelURL: @Sendable () async throws -> URL
    private let keepWarm: @Sendable () -> Duration
    private let lease: LLMLease
    private let priority: LeasePriority

    /// - Parameters:
    ///   - modelURL: the GGUF file to use, asked for at every request so a model chosen in Settings
    ///     applies at once; it throws (`LlamaError.modelNotFound`) when the model is not installed.
    ///   - lease: where the model is kept; the process-wide one in the app. Without it the runtime has a lease
    ///     of its own.
    public init(
        runtime: any LLMRuntime, modelURL: @escaping @Sendable () async throws -> URL,
        keepWarm: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        lease: LLMLease? = nil, priority: LeasePriority = .interactive
    ) {
        self.runtime = runtime
        self.modelURL = modelURL
        self.keepWarm = keepWarm
        self.lease = lease ?? LLMLease(sleep: sleep)
        self.priority = priority
    }

    public init(
        runtime: any LLMRuntime, modelURL: URL, keepWarm: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        lease: LLMLease? = nil, priority: LeasePriority = .interactive
    ) {
        self.init(
            runtime: runtime, modelURL: { modelURL }, keepWarm: keepWarm, sleep: sleep, lease: lease,
            priority: priority)
    }

    /// Loads the model if it is not loaded and starts the keep-warm timer.
    public func warmUp() async throws {
        let handle = try await acquire()
        await handle.release()
    }

    public func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await generateResult(messages: messages, maxTokens: maxTokens).text
    }

    public func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        let handle = try await acquire()
        do {
            let result = try await handle.generateResult(messages: messages, maxTokens: maxTokens)
            await handle.release()
            return result
        } catch {
            await handle.release()
            throw error
        }
    }

    /// Frees the model now (plugin disabled, model deleted, Erase Data) unless someone is using it.
    public func unload() async {
        await lease.evictIdle()
    }

    /// Takes a lease on the model, or on another one when Settings now name a different file.
    private func acquire() async throws -> LLMHandle {
        let url = try await modelURL()
        let key = LLMLease.Key(modelID: url.path, contextLength: runtime.contextLength)
        return try await lease.acquire(
            key: key, runtime: runtime, modelURL: url, priority: priority, keepWarm: keepWarm)
    }
}
