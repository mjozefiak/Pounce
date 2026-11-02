import Foundation

/// Keeps a model loaded for a while after its last use and frees it afterwards (spec: `keepWarmMinutes`).
/// The first request after the pause loads it again; `warmUp()` does that ahead of time, when recording starts.
actor KeepWarmRuntime {
    private let runtime: any LLMRuntime
    private let modelURL: URL
    private let keepWarm: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var inFlight = 0
    private var timer: Task<Void, Never>?

    init(
        runtime: any LLMRuntime, modelURL: URL, keepWarm: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runtime = runtime
        self.modelURL = modelURL
        self.keepWarm = keepWarm
        self.sleep = sleep
    }

    /// Loads the model if it is not loaded and starts the keep-warm timer.
    func warmUp() async throws {
        timer?.cancel()
        timer = nil
        defer { scheduleUnload() }
        if await !runtime.isLoaded { try await runtime.load(modelAt: modelURL) }
    }

    func generate(messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> String {
        timer?.cancel()
        timer = nil
        inFlight += 1
        defer {
            inFlight -= 1
            scheduleUnload()
        }
        if await !runtime.isLoaded { try await runtime.load(modelAt: modelURL) }
        return try await runtime.generate(messages: messages, maxTokens: maxTokens)
    }

    /// Frees the model now (plugin disabled, model deleted, Erase Data).
    func unload() async {
        timer?.cancel()
        timer = nil
        await runtime.unload()
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
        await runtime.unload()
    }
}
