import Testing

@testable import DictationPlugin
@testable import LintelKit

@Suite @MainActor struct SkeletonTests {
    @Test func theManifestIsOffByDefaultAndStable() {
        let manifest = DictationPlugin.manifest
        #expect(manifest.id == "dictation")
        #expect(manifest.defaultEnabled == false)
        #expect(manifest.order > 30)
    }
}

@Suite @MainActor struct PluginContractTests {
    @Test func theRecordCommandDeliversKeyPhasesAndNeedsTheMicrophone() throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        let command = try #require(plugin.commands.first)
        #expect(command.id == "dictation.record")
        #expect(command.onKeyEvent != nil)
        #expect(command.defaultShortcut == KeyShortcut(key: "d", modifiers: [.control, .option]))
        #expect(plugin.requiredPermissions == [.microphone, .accessibility])
    }
}
