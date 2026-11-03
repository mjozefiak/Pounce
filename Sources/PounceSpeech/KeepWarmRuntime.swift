import Foundation

/// Keeps a model loaded for a while after its last use and frees it afterwards (spec: `keepWarmMinutes`).
/// The first request after the pause loads it again; `warmUp()` does that ahead of time, when recording starts.
public actor KeepWarmRuntime {
    private let runtime: any LLMRuntime
    private let modelURL: @Sendable () async throws -> URL
    private let keepWarm: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var inFlight = 0
    private var timer: Task<Void, Never>?
    private var loadedURL: URL?

    /// - Parameter modelURL: the GGUF file to use, asked for at every request so a model chosen in Settings
    ///   applies at once; it throws (`LlamaError.modelNotFound`) when the model is not installed.
    public init(
        runtime: any LLMRuntime, modelURL: @escaping @Sendable () async throws -> URL,
        keepWarm: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runtime = runtime
        self.modelURL = modelURL
        self.keepWarm = keepWarm
        self.sleep = sleep
    }

    public init(
        runtime: any LLMRuntime, modelURL: URL, keepWarm: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.init(runtime: runtime, modelURL: { modelURL }, keepWarm: keepWarm, sleep: sleep)
    }

    /// Loads the model if it is not loaded and starts the keep-warm timer.
    public func warmUp() async throws {
        timer?.cancel()
        timer = nil
        defer { scheduleUnload() }
        try await ensureLoaded()
    }

    public func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await generateResult(messages: messages, maxTokens: maxTokens).text
    }

    public func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        timer?.cancel()
        timer = nil
        inFlight += 1
        defer {
            inFlight -= 1
            scheduleUnload()
        }
        try await ensureLoaded()
        return try await runtime.generateResult(messages: messages, maxTokens: maxTokens)
    }

    /// Frees the model now (plugin disabled, model deleted, Erase Data).
    public func unload() async {
        timer?.cancel()
        timer = nil
        loadedURL = nil
        await runtime.unload()
    }

    /// Loads the model, or loads another one when Settings now name a different file.
    private func ensureLoaded() async throws {
        let url = try await modelURL()
        if await runtime.isLoaded, loadedURL == url { return }
        loadedURL = nil
        try await runtime.load(modelAt: url)
        loadedURL = url
    }

    private func scheduleUnload() {
        guard inFlight == 0 else { return }
        timer?.cancel()
        let delay = keepWarm()
        timer = Task { [sleep, runtime] in
            do { try await sleep(delay) } catch { return }
            await self.unloadIfIdle(runtime)
        }
    }

    private func unloadIfIdle(_ runtime: any LLMRuntime) async {
        guard inFlight == 0, !Task.isCancelled else { return }
        loadedURL = nil
        await runtime.unload()
    }
}
