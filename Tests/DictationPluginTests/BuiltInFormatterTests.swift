import Foundation
import PounceKit
import Testing

@testable import DictationPlugin

/// A runtime that answers from a script: a fixed answer, an error, or a long wait.
actor ScriptedRuntime: LLMRuntime {
    var answer = ""
    var generateError: (any Error)?
    var loadError: LlamaError?
    var delay: Duration = .zero
    private(set) var loaded = false
    private(set) var loads = 0
    private(set) var requests: [[CleanupPrompt.Message]] = []
    private(set) var maxTokens: [Int] = []

    var isLoaded: Bool { loaded }

    func script(answer: String? = nil, error: (any Error)? = nil, loadError: LlamaError? = nil, delay: Duration = .zero)
    {
        if let answer { self.answer = answer }
        generateError = error
        self.loadError = loadError
        self.delay = delay
    }

    func load(modelAt url: URL) async throws {
        if let loadError { throw loadError }
        loads += 1
        loaded = true
    }

    func unload() async { loaded = false }

    func generate(messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> String {
        guard loaded else { throw LlamaError.notLoaded }
        requests.append(messages)
        self.maxTokens.append(maxTokens)
        if delay > .zero { try await Task.sleep(for: delay) }
        if let generateError { throw generateError }
        return answer
    }
}

private let spoken = "yyy no więc jutro mamy spotkanie o dziesiątej nie to znaczy o jedenastej w biurze"
private let cleaned = "Jutro mamy spotkanie o dziesiątej, nie to znaczy o jedenastej w biurze."

@Suite struct BuiltInFormatterTests {
    private func make(
        _ runtime: ScriptedRuntime,
        modelURL: @escaping @Sendable () async throws -> URL = {
            URL(fileURLWithPath: "/models/test.gguf")
        },
        timeout: Duration = .seconds(5)
    ) -> (BuiltInFormatter, KeepWarmRuntime) {
        let warm = KeepWarmRuntime(runtime: runtime, modelURL: modelURL, keepWarm: { .seconds(60) })
        return (BuiltInFormatter(runtime: warm, timeout: { _ in timeout }), warm)
    }

    @Test func aCleanedAnswerIsUsed() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: cleaned)
        let (formatter, warm) = make(runtime)
        let result = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(result == FormatResult(text: cleaned, outcome: .formatted))
        // The request carries the cleanup prompt and the word-based token limit.
        let request = try #require(await runtime.requests.first)
        #expect(request.first?.role == "system")
        #expect(request.last?.content.contains("<transcript>\(spoken)</transcript>") == true)
        #expect(await runtime.maxTokens == [FormatterGuard.words(in: spoken) * 4 + 64])
        await warm.unload()
    }

    @Test func thePreviousContextIsPassedOn() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: cleaned)
        let (formatter, warm) = make(runtime)
        _ = try await formatter.format(chunk: spoken, previousContext: "Poprzedni akapit.")
        let request = try #require(await runtime.requests.first)
        #expect(request.last?.content.contains("<context>Poprzedni akapit.</context>") == true)
        await warm.unload()
    }

    /// The guard treats the built-in model exactly like a server's answer.
    @Test(arguments: [
        ("<think>hmm</think>" + cleaned, FormatResult.Outcome.formatted),
        ("", .fellBack(.rejected(.empty))),
        ("Oczywiście, oto poprawiony tekst: " + cleaned, .fellBack(.rejected(.answered))),
        (
            "Tomorrow we have the meeting at eleven in the office with the client",
            .fellBack(.rejected(.languageChanged))
        ),
        ("Jutro spotkanie.", .fellBack(.rejected(.tooShort))),
        (cleaned + " " + cleaned, .fellBack(.rejected(.tooLong))),
    ])
    func theGuardDecides(answer: String, outcome: FormatResult.Outcome) async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: answer)
        let (formatter, warm) = make(runtime)
        let result = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(result.outcome == outcome)
        if outcome != .formatted { #expect(result.text == spoken) }
        await warm.unload()
    }

    @Test func aModelThatIsNotInstalledGivesTheRawChunk() async throws {
        let runtime = ScriptedRuntime()
        let (formatter, _) = make(runtime, modelURL: { throw LlamaError.modelNotFound })
        let result = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(result == FormatResult(text: spoken, outcome: .fellBack(.modelUnavailable)))
    }

    @Test func aModelThatFailsToLoadGivesTheRawChunk() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(loadError: .loadFailed)
        let (formatter, _) = make(runtime)
        let result = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(result.outcome == .fellBack(.modelUnavailable))
    }

    @Test func aDecodeErrorGivesTheRawChunk() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(error: LlamaError.decodeFailed(1))
        let (formatter, warm) = make(runtime)
        let result = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(result == FormatResult(text: spoken, outcome: .fellBack(.badResponse)))
        await warm.unload()
    }

    @Test func aSlowModelGivesTheRawChunkAtTheTimeLimit() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: cleaned, delay: .seconds(30))
        let (formatter, warm) = make(runtime, timeout: .milliseconds(80))
        let started = ContinuousClock.now
        let result = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(result == FormatResult(text: spoken, outcome: .fellBack(.timedOut)))
        #expect(ContinuousClock.now - started < .seconds(5))
        await warm.unload()
    }

    @Test func cancellingTheCallerThrowsCancellation() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: cleaned, delay: .seconds(30))
        let (formatter, warm) = make(runtime)
        let task = Task { try await formatter.format(chunk: spoken, previousContext: nil) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        await warm.unload()
    }

    @Test func prepareLoadsTheModelAheadAndNeverThrows() async throws {
        let runtime = ScriptedRuntime()
        let (formatter, warm) = make(runtime)
        await formatter.prepare()
        #expect(await runtime.isLoaded)
        _ = try await formatter.format(chunk: spoken, previousContext: nil)
        #expect(await runtime.loads == 1)
        await warm.unload()

        let failing = ScriptedRuntime()
        await failing.script(loadError: .loadFailed)
        let (other, _) = make(failing)
        await other.prepare()
        #expect(await failing.isLoaded == false)
    }

    @Test func theTimeLimitAllowsForLoadingTheModel() {
        #expect(BuiltInFormatter.timeout(forWords: 60) == .seconds(LocalLLMFormatter.timeout(forWords: 60) + 20))
    }
}

@Suite struct FirstResultTests {
    @Test func aFastOperationWins() async throws {
        let value = try await FirstResult.within(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func aSlowOperationIsGivenUpOnWithoutWaitingForIt() async throws {
        let release = Release()
        let started = ContinuousClock.now
        // Ignores cancellation, like a model load that cannot be interrupted.
        let value = try await FirstResult.within(.milliseconds(60)) { await release.wait() }
        #expect(value == nil)
        #expect(ContinuousClock.now - started < .seconds(3))
        await release.open()
    }

    @Test func cancellingTheCallerThrows() async throws {
        let release = Release()
        let task = Task { try await FirstResult.within(.seconds(30)) { await release.wait() } }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        await release.open()
    }
}

/// An operation that finishes only when the test lets it, whatever its task's cancellation state.
private actor Release {
    private var continuation: CheckedContinuation<Int, Never>?
    private var opened = false

    func wait() async -> Int {
        if opened { return 1 }
        return await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume(returning: 1)
        continuation = nil
    }
}

@Suite struct BuiltInSettingsTests {
    private func settings() -> DictationSettings {
        DictationSettings(PluginSettings(pluginID: "dictation", store: MemorySettingsStore()))
    }

    @Test func theServerIsTheDefaultSource() {
        #expect(settings().llmSource == .server)
    }

    @Test func theSourceAndTheModelAreStored() {
        let settings = settings()
        settings.setLLMSource(.builtIn)
        settings.setBuiltInLLMModel(LLMModelCatalog.qwen3Large)
        #expect(settings.llmSource == .builtIn)
        #expect(settings.builtInLLMModel == LLMModelCatalog.qwen3Large)
    }

    @Test func anUnknownStoredModelFallsBackToTheDefault() {
        let store = MemorySettingsStore()
        let settings = DictationSettings(PluginSettings(pluginID: "dictation", store: store))
        PluginSettings(pluginID: "dictation", store: store).set("removed-model", for: "builtInLLMModel")
        #expect(settings.builtInLLMModel == LLMModelCatalog.defaultModel)
    }
}

@Suite struct KeepWarmModelSwitchTests {
    @Test func aDifferentModelInSettingsIsLoadedAtTheNextRequest() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: "ok")
        let current = Current(URL(fileURLWithPath: "/models/a.gguf"))
        let warm = KeepWarmRuntime(runtime: runtime, modelURL: { await current.url }, keepWarm: { .seconds(60) })
        _ = try await warm.generate(messages: [], maxTokens: 4)
        _ = try await warm.generate(messages: [], maxTokens: 4)
        #expect(await runtime.loads == 1)
        await current.set(URL(fileURLWithPath: "/models/b.gguf"))
        _ = try await warm.generate(messages: [], maxTokens: 4)
        #expect(await runtime.loads == 2)
        await warm.unload()
    }

    private actor Current {
        var url: URL
        init(_ url: URL) { self.url = url }
        func set(_ url: URL) { self.url = url }
    }
}

/// Counts the warm-ups and formats nothing.
private actor PrepareSpy: TextFormatter {
    private(set) var prepared = 0

    func format(chunk: String, previousContext: String?) async throws -> FormatResult { .raw(chunk) }
    func prepare() async { prepared += 1 }
}

@Suite struct BuiltInSessionTests {
    private func session(formatter: any TextFormatter) -> DictationSession {
        DictationSession(
            audio: ScriptedAudioInput(seconds: 5),
            vad: RangeVAD([AudioFormat.sampleRate..<(2 * AudioFormat.sampleRate)]), engine: FakeEngine(),
            formatter: formatter, modelFolder: URL(filePath: "/tmp/none"))
    }

    @Test func theFormatterIsPreparedWhenRecordingStarts() async throws {
        let spy = PrepareSpy()
        let session = session(formatter: spy)
        try await session.start()
        for _ in 0..<1000 where await spy.prepared == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await spy.prepared == 1)
        _ = try await session.finish()
    }

    @Test func aDictationIsFormattedByTheBuiltInModelAndTheModelWasLoadedWhileRecording() async throws {
        let runtime = ScriptedRuntime()
        await runtime.script(answer: "Segment 1.")
        let warm = KeepWarmRuntime(
            runtime: runtime, modelURL: URL(fileURLWithPath: "/models/test.gguf"), keepWarm: { .seconds(60) })
        let session = session(formatter: BuiltInFormatter(runtime: warm))
        try await session.start()
        for _ in 0..<1000 where await !runtime.isLoaded { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await runtime.isLoaded)
        let output = try await session.finish()
        #expect(output.text == "Segment 1.")
        #expect(output.rawText == "segment 1")
        #expect(output.formatting.fellBack == 0)
        #expect(await runtime.loads == 1)
        await warm.unload()
    }

    @Test func aMissingModelStillPastesTheRawText() async throws {
        let warm = KeepWarmRuntime(
            runtime: ScriptedRuntime(), modelURL: { throw LlamaError.modelNotFound }, keepWarm: { .seconds(60) })
        let session = session(formatter: BuiltInFormatter(runtime: warm))
        try await session.start()
        let output = try await session.finish()
        #expect(output.text == "segment 1")
        #expect(output.formatting.fellBack == output.formatting.chunks)
        #expect(output.formatting.firstReason == .modelUnavailable)
    }
}

/// Cleans two Polish dictations with the real GGUF in `POUNCE_LLAMA_MODEL` through the whole built-in path
/// (`KeepWarmRuntime`, `BuiltInFormatter`, the guard). Off by default; the full fixture set is step 4.5.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"] != nil))
struct RealBuiltInFormatterTests {
    @Test func cleansPolishDictationsWithTheRealModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"])
        let warm = KeepWarmRuntime(
            runtime: LlamaRuntime(), modelURL: URL(fileURLWithPath: path), keepWarm: { .seconds(60) })
        let formatter = BuiltInFormatter(runtime: warm)
        await formatter.prepare()
        for (spoken, needle) in [
            (spoken, "jedenastej"),
            ("yyy no więc jak zrobić backup bazy w postgresie bo nie pamiętam", "backup"),
        ] {
            let started = ContinuousClock.now
            let result = try await formatter.format(chunk: spoken, previousContext: nil)
            print("[builtin] \(ContinuousClock.now - started) \(result.outcome): \(result.text)")
            #expect(result.outcome == .formatted)
            #expect(result.text.localizedCaseInsensitiveContains(needle))
        }
        await warm.unload()
    }
}
