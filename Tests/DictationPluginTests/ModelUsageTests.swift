import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import DictationPlugin

/// Spec `2026-11-04-lintel-main-window`, step 3.2: the models Dictation declares for the shell's Models pane.
@MainActor
@Suite struct DictationModelUsageTests {
    @Test func declaresTheRequiredSpeechModelAndTheOptionalFormattingModel() throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        let usages = plugin.modelUsage
        #expect(usages.map(\.kind) == [.speech, .llm])
        #expect(usages[0].packageID == ModelCatalog.parakeetUltra.id)
        #expect(usages[0].isRequired && usages[0].isSelected)
        #expect(usages[0].chooseFolder != nil)
        #expect(usages[1].packageID == LLMModelCatalog.defaultModel.id)
        #expect(!usages[1].isRequired)
        // The server is the default source: the built-in model is not selected.
        #expect(!usages[1].isSelected)
        #expect(usages[1].chooseFolder == nil)
    }

    @Test func theBuiltInModelIsSelectedOnlyForTheBuiltInSource() throws {
        let harness = try DictationHarness(settings: [
            "plugins.dictation.llmSource": .string("builtIn"),
            "plugins.dictation.speechModel": .string(ModelCatalog.whisperLargeV3Turbo.id),
        ])
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        #expect(plugin.modelUsage[0].packageID == ModelCatalog.whisperLargeV3Turbo.id)
        #expect(plugin.modelUsage[1].isSelected)
    }

    @Test func chooseFolderWritesTheSpeechFolderKey() throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        let folder = harness.directory.url.appending(path: "hand", directoryHint: .isDirectory)
        plugin.modelUsage[0].chooseFolder?(folder)
        #expect(plugin.settings.speechModelFolder?.path == folder.path)
    }

    @Test func nothingIsInUseWhileIdle() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        #expect(await plugin.modelUsage[0].isInUse() == false)
        // No model file is installed, so no lease can hold it.
        #expect(await plugin.modelUsage[1].isInUse() == false)
    }

    @Test func aChosenSpeechFolderIsNotRequired() throws {
        let harness = try DictationHarness(settings: [
            "plugins.dictation.speechModelFolder": .string(FileManager.default.temporaryDirectory.path)
        ])
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        // The Models pane does not see the chosen folder, so the model must not count as missing.
        #expect(!plugin.modelUsage[0].isRequired)
        #expect(plugin.modelUsage[0].isSelected)
    }

    @Test func theSpeechModelIsInUseWhileTheControllerIsBusy() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        let rig = try DictationControllerTests.Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        plugin.relay.controller = controller
        #expect(await plugin.modelUsage[0].isInUse() == false)
        controller.menu()
        #expect(controller.isBusy)
        #expect(await plugin.modelUsage[0].isInUse())
        controller.cancel()
        for _ in 0..<1_000 where controller.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await plugin.modelUsage[0].isInUse() == false)
    }

    @Test func theFormattingModelIsInUseWhileARequestHoldsIt() async throws {
        let harness = try DictationHarness(settings: ["plugins.dictation.llmSource": .string("builtIn")])
        defer { harness.tearDown() }
        let url = URL(fileURLWithPath: "/models/in-use.gguf")
        let lease = LLMLease()
        let scripted = ScriptedRuntime()
        let plugin = DictationPlugin(
            context: harness.context,
            makeBuiltInLLM: { _, _ in
                KeepWarmRuntime(runtime: scripted, modelURL: url, keepWarm: { .seconds(60) }, lease: lease)
            })
        #expect(await plugin.modelUsage[1].isInUse() == false)
        let handle = try await lease.acquire(
            key: .init(modelID: url.path, contextLength: scripted.contextLength), runtime: scripted, modelURL: url,
            priority: .interactive, keepWarm: { .seconds(60) })
        #expect(await plugin.modelUsage[1].isInUse())
        await handle.release()
        #expect(await plugin.modelUsage[1].isInUse() == false)
        await lease.evictIdle()
    }
}
