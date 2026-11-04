import Foundation
import PounceKit
import Testing

@testable import DictationPlugin
@testable import PounceSpeech

@MainActor
@Suite(.serialized) struct FormattingSettingsTests {
    private func model(
        _ store: MemorySettingsStore = MemorySettingsStore(), transport: any HTTPTransport
    ) -> (FormattingSettingsModel, DictationSettings) {
        let settings = DictationSettings(PluginSettings(pluginID: "dictation", store: store))
        return (FormattingSettingsModel(settings: settings, transport: transport), settings)
    }

    private func listing() -> LoopbackTransport {
        LoopbackStub.reset()
        LoopbackStub.register("127.0.0.1:11434/v1/models", .json(#"{"data":[{"id":"qwen"},{"id":"bielik"}]}"#))
        LoopbackStub.register("127.0.0.1:1234/v1/models", .json(#"{"data":[{"id":"lm"}]}"#))
        return LoopbackTransport(protocolClasses: [LoopbackStub.self])
    }

    @Test func formattingIsOffByDefault() {
        let (model, settings) = model(transport: ScriptedTransport(.content("x")))
        #expect(model.mode == .raw)
        #expect(settings.mode == .raw)
        #expect(settings.llmTarget == nil)
    }

    @Test func switchingItOnTakesTheFirstServerAndModel() async {
        let (model, settings) = model(transport: listing())
        model.mode = .cleanup
        await model.refresh()
        #expect(model.endpoints.map(\.name) == ["Ollama", "LM Studio"])
        #expect(settings.mode == .cleanup)
        #expect(settings.llmTarget?.baseURL.absoluteString == "http://127.0.0.1:11434")
        #expect(settings.llmTarget?.model == "qwen")
    }

    @Test func choosingAnotherServerPicksItsModel() async throws {
        let (model, settings) = model(transport: listing())
        model.mode = .cleanup
        await model.refresh()
        model.chooseEndpoint(try #require(URL(string: "http://127.0.0.1:1234")))
        #expect(settings.llmTarget?.model == "lm")
        model.chooseModel(nil)
        #expect(settings.llmTarget == nil)
    }

    @Test func aModelThatDisappearedIsReplaced() async {
        let store = MemorySettingsStore([
            "plugins.dictation.llmEndpoint": .string("http://127.0.0.1:11434"),
            "plugins.dictation.llmModel": .string("gone"),
            "plugins.dictation.mode": .string("cleanup"),
        ])
        let (model, settings) = model(store, transport: listing())
        await model.refresh()
        #expect(settings.llmModel == "qwen")
    }

    @Test func anAddressOffThisMacIsRefusedAndNotStored() {
        let (model, settings) = model(transport: ScriptedTransport(.content("x")))
        model.address = "http://example.com:11434"
        #expect(model.addressError)
        #expect(settings.llmEndpoint == nil)
        model.address = "localhost:8080"
        #expect(!model.addressError)
        #expect(settings.llmEndpoint?.absoluteString == "http://127.0.0.1:8080")
    }

    @Test func aStoredNonLoopbackAddressIsNeverUsed() {
        let store = MemorySettingsStore([
            "plugins.dictation.llmEndpoint": .string("http://192.168.1.5:11434"),
            "plugins.dictation.llmModel": .string("m"),
        ])
        let (_, settings) = model(store, transport: ScriptedTransport(.content("x")))
        #expect(settings.llmEndpoint == nil)
        #expect(settings.llmTarget == nil)
    }

    @Test func tryItShowsTheCleanedSample() async throws {
        let store = MemorySettingsStore([
            "plugins.dictation.llmEndpoint": .string("http://127.0.0.1:11434"),
            "plugins.dictation.llmModel": .string("qwen"),
        ])
        let transport = ScriptedTransport(
            .content("Jutro mamy spotkanie o dziesiątej, nie, to znaczy o jedenastej w biurze."))
        let (model, _) = model(store, transport: transport)
        model.tryIt()
        for _ in 0..<200 where model.tryState == .running { try await Task.sleep(for: .milliseconds(10)) }
        #expect(
            model.tryState
                == .result(
                    original: FormattingSettingsModel.sample,
                    text: "Jutro mamy spotkanie o dziesiątej, nie, to znaczy o jedenastej w biurze.",
                    cleaned: true))
    }

    @Test func tryItReportsAFallbackWhenTheServerIsDown() async throws {
        let store = MemorySettingsStore([
            "plugins.dictation.llmEndpoint": .string("http://127.0.0.1:11434"),
            "plugins.dictation.llmModel": .string("qwen"),
        ])
        let (model, _) = model(store, transport: ScriptedTransport(.failure(.cannotConnectToHost)))
        model.tryIt()
        for _ in 0..<200 where model.tryState == .running { try await Task.sleep(for: .milliseconds(10)) }
        guard case .result(_, let text, let cleaned) = model.tryState else {
            Issue.record("no result")
            return
        }
        #expect(!cleaned)
        #expect(text == FormattingSettingsModel.sample)
    }
}

/// The text fixtures of the prompt regression (step 2.5), and the optional run against a real server.
@Suite struct CleanupFixtureTests {
    struct Case: Decodable, Sendable {
        let id: String
        let language: String
        let raw: String
        let mustContain: [String]
        let mustNotContain: [String]
        let isQuestionOrCommand: Bool
    }

    static func load() throws -> [Case] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/cleanup/cases", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    @Test func fixturesCoverPolishEnglishMixedAndDictatedQuestionsAndCommands() throws {
        let cases = try Self.load()
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(cases.contains { $0.language == "pl" })
        #expect(cases.contains { $0.language == "en" })
        #expect(cases.contains { $0.id.hasPrefix("mixed") })
        #expect(cases.filter(\.isQuestionOrCommand).count >= 4)
        #expect(cases.allSatisfy { !$0.raw.isEmpty && !$0.mustContain.isEmpty })
    }

    /// Runs every fixture against the server in `POUNCE_LLM_URL` with the model in `POUNCE_LLM_MODEL` and
    /// prints a table for the PR body. Off by default, like the benchmarks.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POUNCE_LLM_URL"] != nil))
    func realServer() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = try #require(env["POUNCE_LLM_URL"].flatMap { LoopbackPolicy.parse($0) })
        let model = try #require(env["POUNCE_LLM_MODEL"])
        let formatter = LocalLLMFormatter(
            transport: LoopbackTransport(), target: { .init(baseURL: base, model: model) })
        var failures: [String] = []
        for fixture in try Self.load() {
            let started = ContinuousClock.now
            let result = try await formatter.format(chunk: fixture.raw, previousContext: nil)
            let elapsed = ContinuousClock.now - started
            print("[cleanup] \(fixture.id) \(result.outcome == .formatted ? "formatted" : "RAW") \(elapsed)")
            print("[cleanup]   in:  \(fixture.raw)\n[cleanup]   out: \(result.text)")
            if result.outcome != .formatted { failures.append("\(fixture.id): fell back \(result.outcome)") }
            for needle in fixture.mustContain where !result.text.localizedCaseInsensitiveContains(needle) {
                failures.append("\(fixture.id): missing \(needle)")
            }
            for needle in fixture.mustNotContain where result.text.localizedCaseInsensitiveContains(needle) {
                failures.append("\(fixture.id): contains \(needle)")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Runs every fixture against the built-in engine with the GGUF file in `POUNCE_LLAMA_MODEL` (step 4.5) and
    /// prints a table for the PR body. Off by default, like the benchmarks.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"] != nil))
    func builtInModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POUNCE_LLAMA_MODEL"])
        let warm = KeepWarmRuntime(
            runtime: LlamaRuntime(), modelURL: URL(fileURLWithPath: path), keepWarm: { .seconds(300) })
        let formatter = BuiltInFormatter(runtime: warm)
        await formatter.prepare()
        var failures: [String] = []
        for fixture in try Self.load() {
            let started = ContinuousClock.now
            let result = try await formatter.format(chunk: fixture.raw, previousContext: nil)
            let elapsed = ContinuousClock.now - started
            print("[cleanup-builtin] \(fixture.id) \(result.outcome == .formatted ? "formatted" : "RAW") \(elapsed)")
            print("[cleanup-builtin]   in:  \(fixture.raw)\n[cleanup-builtin]   out: \(result.text)")
            if result.outcome != .formatted { failures.append("\(fixture.id): fell back \(result.outcome)") }
            for needle in fixture.mustContain where !result.text.localizedCaseInsensitiveContains(needle) {
                failures.append("\(fixture.id): missing \(needle)")
            }
            for needle in fixture.mustNotContain where result.text.localizedCaseInsensitiveContains(needle) {
                failures.append("\(fixture.id): contains \(needle)")
            }
        }
        await warm.unload()
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}

/// The built-in source of the Formatting section (step 4.4).
@MainActor
@Suite(.serialized) struct BuiltInFormattingSettingsTests {
    private func make(
        _ store: MemorySettingsStore = MemorySettingsStore(), memory: UInt64 = UInt64(16) << 30, offered: Bool = true
    ) throws -> (FormattingSettingsModel, DictationSettings, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        let settings = DictationSettings(PluginSettings(pluginID: "dictation", store: store))
        let manager = ModelManager(directory: directory.url, availableSpace: { _ in Int.max })
        let model = FormattingSettingsModel(
            settings: settings, transport: ScriptedTransport(.content("x")), llmModels: offered ? manager : nil,
            physicalMemory: memory)
        return (model, settings, directory)
    }

    @Test func theServerStaysTheDefaultSource() throws {
        let (model, settings, directory) = try make()
        withExtendedLifetime(directory) {
            #expect(model.source == .server)
            #expect(settings.llmSource == .server)
            #expect(!model.isBuiltIn)
        }
    }

    @Test func choosingTheBuiltInSourceIsStoredAndNeedsTheDownload() async throws {
        let (model, settings, directory) = try make()
        defer { withExtendedLifetime(directory) {} }
        model.mode = .cleanup
        model.source = .builtIn
        await model.refreshBuiltIn()
        #expect(settings.llmSource == .builtIn)
        #expect(model.isBuiltIn)
        #expect(!model.isBuiltInInstalled)
        #expect(!model.hasTarget)
    }

    @Test func withoutAModelManagerTheBuiltInSourceIsHiddenAndIgnored() throws {
        let store = MemorySettingsStore(["plugins.dictation.llmSource": .string("builtIn")])
        let (model, _, directory) = try make(store, offered: false)
        withExtendedLifetime(directory) {
            #expect(!model.offersBuiltIn)
            #expect(!model.isBuiltIn)
            #expect(model.source == .server)
        }
    }

    @Test func theLargeModelIsOfferedOnlyWithEnoughMemory() throws {
        let (small, _, first) = try make(memory: UInt64(16) << 30)
        let (large, _, second) = try make(memory: UInt64(64) << 30)
        withExtendedLifetime((first, second)) {
            #expect(small.builtInModels == [LLMModelCatalog.qwen3Small])
            #expect(large.builtInModels == LLMModelCatalog.all)
        }
    }

    @Test func aStoredModelThisMacCannotHoldFallsBackToTheOfferedOne() throws {
        let store = MemorySettingsStore([
            "plugins.dictation.builtInLLMModel": .string(LLMModelCatalog.qwen3Large.id)
        ])
        let (model, _, directory) = try make(store, memory: UInt64(16) << 30)
        withExtendedLifetime(directory) {
            #expect(model.builtInModel == LLMModelCatalog.qwen3Small)
        }
    }

    @Test func choosingAnotherBuiltInModelIsStored() throws {
        let (model, settings, directory) = try make(memory: UInt64(64) << 30)
        withExtendedLifetime(directory) {
            model.chooseBuiltInModel(LLMModelCatalog.qwen3Large.id)
            #expect(model.builtInModel == LLMModelCatalog.qwen3Large)
            #expect(settings.builtInLLMModel == LLMModelCatalog.qwen3Large)
            model.chooseBuiltInModel("unknown")
            #expect(model.builtInModel == LLMModelCatalog.qwen3Large)
        }
    }

    @Test func removingAMissingModelIsHarmless() async throws {
        let (model, _, directory) = try make()
        defer { withExtendedLifetime(directory) {} }
        model.removeBuiltIn()
        await model.refreshBuiltIn()
        #expect(model.builtInError == nil)
        #expect(!model.isBuiltInInstalled)
    }

    @Test func aModelThatIsInUseIsNotRemoved() async throws {
        let directory = try TemporaryDirectory()
        let settings = DictationSettings(PluginSettings(pluginID: "dictation", store: MemorySettingsStore()))
        let manager = ModelManager(directory: directory.url, availableSpace: { _ in Int.max })
        let url = URL(fileURLWithPath: "/models/in-use.gguf")
        let lease = LLMLease()
        let scripted = ScriptedRuntime()
        let warm = KeepWarmRuntime(
            runtime: scripted, modelURL: url, keepWarm: { .seconds(60) }, lease: lease)
        let model = FormattingSettingsModel(
            settings: settings, transport: ScriptedTransport(.content("x")), llmModels: manager, runtime: warm)

        // A request holds the model: Remove refuses, says why and leaves the loaded copy alone.
        let handle = try await lease.acquire(
            key: .init(modelID: url.path, contextLength: scripted.contextLength), runtime: scripted, modelURL: url,
            priority: .interactive, keepWarm: { .seconds(60) })
        #expect(await warm.isInUse())
        model.removeBuiltIn()
        for _ in 0..<2_000 where model.builtInError == nil { await Task.yield() }
        #expect(model.builtInError != nil)
        #expect(await scripted.loaded)

        // Positive control: once the request is over, removal goes through (nothing to delete here) and the
        // model is freed.
        await handle.release()
        #expect(!(await warm.isInUse()))
        model.removeBuiltIn()
        for _ in 0..<2_000 where model.builtInError != nil { await Task.yield() }
        #expect(model.builtInError == nil)
        for _ in 0..<2_000 where await scripted.loaded { await Task.yield() }
        #expect(!(await scripted.loaded))
        withExtendedLifetime(directory) {}
    }
}
