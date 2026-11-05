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
}
