import Foundation
import Testing

@testable import PounceSpeech

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

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        guard loaded else { throw LlamaError.notLoaded }
        generations += 1
        if delay > .zero { try await Task.sleep(for: delay) }
        return answer
    }
}

private let sampleMessages = [
    ChatMessage(role: "system", content: "Clean up the transcript."),
    ChatMessage(role: "user", content: "yyy no więc jutro mamy spotkanie"),
]

/// Polls until the stub has unloaded `count` times, for at most ten seconds (a fixed sleep flakes on a loaded runner).
private func waitForUnloads(_ stub: StubRuntime, _ count: Int) async {
    for _ in 0..<1000 {
        if await stub.unloads >= count { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

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
        await waitForUnloads(stub, 1)
        #expect(await stub.isLoaded == false)
        #expect(await stub.unloads == 1)
        // The next request loads it again.
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        #expect(await stub.loads.count == 2)
        await runtime.unload()
    }

    @Test func aNewRequestRestartsTheTimer() async throws {
        let stub = StubRuntime()
        let runtime = make(stub, keepWarm: .seconds(3))
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        try await Task.sleep(for: .milliseconds(1800))
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        try await Task.sleep(for: .milliseconds(1800))
        #expect(await stub.isLoaded)
        await runtime.unload()
    }

    @Test func theModelIsNotFreedWhileARequestRuns() async throws {
        let stub = StubRuntime()
        await stub.setDelay(.milliseconds(200))
        let runtime = make(stub, keepWarm: .milliseconds(20))
        _ = try await runtime.generate(messages: sampleMessages, maxTokens: 8)
        #expect(await stub.unloads == 0)
        await waitForUnloads(stub, 1)
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

@Suite struct GenerationResultTests {
    @Test func aRuntimeThatCannotTellReportsACompletionThatFinishedByItself() async throws {
        let stub = StubRuntime()
        try await stub.load(modelAt: URL(fileURLWithPath: "/models/test.gguf"))
        let result = try await stub.generateResult(messages: sampleMessages, maxTokens: 8)
        #expect(result == GenerationResult(text: "cleaned", stoppedByTokenLimit: false))
    }

    @Test func keepWarmPassesTheResultThrough() async throws {
        let runtime = KeepWarmRuntime(
            runtime: StubRuntime(), modelURL: URL(fileURLWithPath: "/models/test.gguf"), keepWarm: { .seconds(60) })
        let result = try await runtime.generateResult(messages: sampleMessages, maxTokens: 8)
        #expect(result.text == "cleaned")
        #expect(try await runtime.generate(messages: sampleMessages, maxTokens: 8) == "cleaned")
        await runtime.unload()
    }
}

@Suite struct LlamaRuntimeTests {
    @Test func theContextLengthDefaultsToWhatDictationNeedsAndCanBeChosen() async {
        #expect(await LlamaRuntime().contextLength == 4096)
        #expect(await LlamaRuntime(contextLength: 8192).contextLength == 8192)
    }

    /// Loads the GGUF in `POUNCE_LLAMA_MODEL` and checks the completion and the token limit flag. Off by default,
    /// like the other real-model tests (ADR 0005).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"] != nil))
    func realModelReportsTheTokenLimit() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"])
        let runtime = LlamaRuntime(contextLength: 2048)
        try await runtime.load(modelAt: URL(fileURLWithPath: path))
        let messages = [ChatMessage(role: "user", content: "Count from one to fifty in words, separated by commas.")]
        let cut = try await runtime.generateResult(messages: messages, maxTokens: 4)
        #expect(cut.stoppedByTokenLimit)
        #expect(!cut.text.isEmpty)
        let short = [ChatMessage(role: "user", content: "Reply with the single word: ok")]
        let done = try await runtime.generateResult(messages: short, maxTokens: 64)
        #expect(!done.stoppedByTokenLimit)
        #expect(try await runtime.generate(messages: short, maxTokens: 64).isEmpty == false)
        await runtime.unload()
    }

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
}
