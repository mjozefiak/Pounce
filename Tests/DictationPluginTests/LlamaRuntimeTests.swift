import Foundation
import Testing

@testable import DictationPlugin

/// A runtime that records what it was asked and answers with a fixed text.
actor StubRuntime: LLMRuntime {
    private(set) var loads: [URL] = []
    private(set) var unloads = 0
    private(set) var generations = 0
    private var loaded = false
    var answer = "cleaned"
    var delay: Duration = .zero
    var loadError: LlamaError?

    var isLoaded: Bool { loaded }

    func setDelay(_ delay: Duration) { self.delay = delay }
    func setLoadError(_ error: LlamaError?) { loadError = error }

    func load(modelAt url: URL) async throws {
        if let loadError { throw loadError }
        loads.append(url)
        loaded = true
    }

    func unload() async {
        unloads += 1
        loaded = false
    }

    func generate(messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> String {
        guard loaded else { throw LlamaError.notLoaded }
        generations += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return answer
    }
}

private let sampleMessages = CleanupPrompt.messages(transcript: "yyy no więc jutro mamy spotkanie", context: nil)

@Suite struct KeepWarmRuntimeTests {
    private let model = URL(fileURLWithPath: "/models/test.gguf")

    private func make(_ stub: StubRuntime, keepWarm: Duration = .milliseconds(40)) -> KeepWarmRuntime {
        KeepWarmRuntime(runtime: stub, modelURL: model, keepWarm: { keepWarm })
    }

    @Test func theFirstRequestLoadsTheModelOnce() async throws {
        let stub = StubRuntime()
        let runtime = make(stub, keepWarm: .seconds(60))
        #expect(try await runtime.generate(messages: sampleMessages, maxTokens: 8) == "cleaned")
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        #expect(await stub.loads == [model])
        #expect(await stub.generations == 2)
        await runtime.unload()
    }

    @Test func theModelIsFreedAfterTheKeepWarmInterval() async throws {
        let stub = StubRuntime()
        let runtime = make(stub)
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        try await Task.sleep(for: .milliseconds(250))
        #expect(await stub.isLoaded == false)
        #expect(await stub.unloads == 1)
        // The next request loads it again.
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        #expect(await stub.loads.count == 2)
        await runtime.unload()
    }

    @Test func aNewRequestRestartsTheTimer() async throws {
        let stub = StubRuntime()
        let runtime = make(stub, keepWarm: .milliseconds(150))
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        try await Task.sleep(for: .milliseconds(90))
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        try await Task.sleep(for: .milliseconds(90))
        #expect(await stub.isLoaded)
        await runtime.unload()
    }

    @Test func theModelIsNotFreedWhileARequestRuns() async throws {
        let stub = StubRuntime()
        await stub.setDelay(.milliseconds(200))
        let runtime = make(stub, keepWarm: .milliseconds(20))
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        #expect(await stub.unloads == 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await stub.unloads == 1)
    }

    @Test func warmUpLoadsAheadOfTheFirstRequest() async throws {
        let stub = StubRuntime()
        let runtime = make(stub, keepWarm: .seconds(60))
        try await runtime.warmUp()
        #expect(await stub.isLoaded)
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        #expect(await stub.loads.count == 1)
        await runtime.unload()
    }

    @Test func aLoadErrorReachesTheCaller() async {
        let stub = StubRuntime()
        await stub.setLoadError(.loadFailed)
        let runtime = make(stub, keepWarm: .seconds(60))
        await #expect(throws: LlamaError.loadFailed) {
            _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        }
        await runtime.unload()
    }
}

@Suite struct LlamaRuntimeTests {
    @Test func aMissingFileIsReported() async {
        let runtime = LlamaRuntime()
        await #expect(throws: LlamaError.modelNotFound) {
            try await runtime.load(modelAt: URL(fileURLWithPath: "/nonexistent/model.gguf"))
        }
        #expect(await runtime.isLoaded == false)
    }

    @Test func aFileThatIsNotAModelIsRejectedWithoutCrashing() async throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appending(path: "not-a-model.gguf")
        try Data("this is not a GGUF file".utf8).write(to: file)
        let runtime = LlamaRuntime()
        await #expect(throws: LlamaError.loadFailed) { try await runtime.load(modelAt: file) }
        #expect(await runtime.isLoaded == false)
        withExtendedLifetime(directory) {}
    }

    @Test func generatingWithoutAModelFails() async {
        await #expect(throws: LlamaError.notLoaded) {
            _ = try await LlamaRuntime().generate(messages: sampleMessages, maxTokens: 8)
        }
    }

    /// Loads the GGUF in `POUNCE_LLAMA_MODEL` and cleans a Polish dictation with the real prompt. Off by default,
    /// like the other real-model tests (ADR 0005).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"] != nil))
    func realModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"])
        let runtime = LlamaRuntime()
        let loadStarted = ContinuousClock.now
        try await runtime.load(modelAt: URL(fileURLWithPath: path))
        print("[llama] load \(ContinuousClock.now - loadStarted)")
        #expect(await runtime.isLoaded)

        let transcript = "yyy no więc jutro mamy spotkanie o dziesiątej nie to znaczy o jedenastej w biurze"
        let messages = CleanupPrompt.messages(transcript: transcript, context: nil)
        for run in ["first", "second"] {
            let started = ContinuousClock.now
            let text = try await runtime.generate(messages: messages, maxTokens: 96)
            print("[llama] \(run) request \(ContinuousClock.now - started): \(text)")
            #expect(!text.isEmpty)
            #expect(text.localizedCaseInsensitiveContains("jedenastej"))
            #expect(FormatterGuard.check(input: transcript, output: text) != .rejected(.empty))
        }

        // Cancelling stops the decode and leaves the runtime usable.
        let task = Task { try await runtime.generate(messages: messages, maxTokens: 512) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await runtime.generate(messages: messages, maxTokens: 96).isEmpty == false)

        await runtime.unload()
        #expect(await runtime.isLoaded == false)
    }
}
