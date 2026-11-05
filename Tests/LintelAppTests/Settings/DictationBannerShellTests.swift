import Foundation
import LintelKit
import LintelSpeech
import Testing

@testable import DictationPlugin
@testable import LintelApp

/// A microphone answer that does not depend on what macOS knows about the test process.
nonisolated struct FixedMicrophone: MicrophoneAuthorizer {
    let access: MicrophoneAccess

    init(_ access: MicrophoneAccess) {
        self.access = access
    }

    func status() -> MicrophoneAccess { access }
    func requestAccess() async -> Bool { access == .granted }
}

/// A real plugin's context from the test environment, with the permission states the test chooses, and the banner
/// the shell derives from it.
enum BannerContext {
    static func make(_ env: TestEnvironment, _ manifest: PluginManifest, reader: any PermissionsReader) -> PluginContext
    {
        let base = env.environment.makeContext(for: manifest)
        return PluginContext(
            storageDirectory: base.storageDirectory, settings: base.settings, usage: base.usage, logger: base.logger,
            keychain: base.keychain, pasteboard: base.pasteboard, events: base.events, workspace: base.workspace,
            permissions: reader, clock: base.clock, cachesDirectory: base.cachesDirectory,
            modelsDirectory: base.modelsDirectory)
    }

    static func banner(_ plugin: any LintelPlugin, reader: any PermissionsReader) -> StatusDerivation.Banner? {
        StatusDerivation.banner(
            host: .active, pluginStatus: { plugin.settingsStatus }, required: Array(plugin.requiredPermissions),
            permission: { reader.status(of: $0) })
    }
}

/// Spec `2026-11-04-lintel-main-window`, step 5.1 review fix: the number in the Dictation banner's title equals the
/// problems the banner lists, the shell's denied permissions included.
@MainActor
@Suite(.serialized) struct DictationBannerShellTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
    }

    @Test func aDeniedAccessibilityIsCountedWithThePluginsTwoThings() async throws {
        defer { env.tearDown() }
        let reader = FakePermissionsReader()
        reader.answers[.accessibility] = .denied
        let plugin = DictationPlugin(
            context: BannerContext.make(env, DictationPlugin.manifest, reader: reader), makeBuiltInLLM: nil,
            authorizer: FixedMicrophone(.notDetermined))
        try await plugin.activate()
        let banner = try #require(BannerContext.banner(plugin, reader: reader))
        // The microphone and the model (the plugin's), Accessibility (the shell's line): three listed, three counted.
        #expect(banner.level == .attention)
        #expect(banner.title == "3 things to do")
        let detail = try #require(banner.detail)
        #expect(detail.contains("Allow the microphone and get the speech model."))
        #expect(detail.contains("Accessibility: not allowed"))
        await plugin.deactivate()
    }

    @Test func aDeniedMicrophoneAndAMissingModelAreTwoThings() async throws {
        defer { env.tearDown() }
        let reader = FakePermissionsReader()
        reader.answers[.microphone] = .denied
        reader.answers[.accessibility] = .granted
        let plugin = DictationPlugin(
            context: BannerContext.make(env, DictationPlugin.manifest, reader: reader), makeBuiltInLLM: nil,
            authorizer: FixedMicrophone(.denied))
        try await plugin.activate()
        let banner = try #require(BannerContext.banner(plugin, reader: reader))
        #expect(banner.title == "2 things to do")
        let detail = try #require(banner.detail)
        #expect(detail.contains("The speech model isn’t installed."))
        #expect(detail.contains("Microphone: not allowed"))
        await plugin.deactivate()
    }

    @Test func withNothingDeniedTheNumberIsThePluginsOwn() async throws {
        defer { env.tearDown() }
        let reader = FakePermissionsReader()
        reader.answers[.accessibility] = .granted
        let plugin = DictationPlugin(
            context: BannerContext.make(env, DictationPlugin.manifest, reader: reader), makeBuiltInLLM: nil,
            authorizer: FixedMicrophone(.notDetermined))
        try await plugin.activate()
        let banner = try #require(BannerContext.banner(plugin, reader: reader))
        #expect(banner.title == "2 things to do")
        #expect(banner.detail == "Allow the microphone and get the speech model.")
        await plugin.deactivate()
    }
}
