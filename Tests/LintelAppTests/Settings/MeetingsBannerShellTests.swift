import Foundation
import LintelKit
import Testing

@testable import LintelApp
@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 5.2: the banner the shell draws above Settings → Meetings, with the
/// real plugin. Turning it on opens its library in the test environment only; nothing records.
@MainActor
@Suite(.serialized) struct MeetingsBannerShellTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
    }

    @Test func meetingsOffShowTheNeutralTurnOnBanner() async throws {
        defer { env.tearDown() }
        let host = env.makeHost([MeetingsPlugin.self])
        await host.start()
        let model = SettingsHostModel(host: host, reader: FakePermissionsReader())
        model.show("meetings")
        let banner = try #require(model.banner)
        #expect(banner.level == .neutral)
        #expect(banner.title == "This feature is off")
        let action = try #require(banner.actions.first)
        guard case .enablePlugin = action.destination else {
            Issue.record("not Turn On")
            return
        }
        #expect(model.attention["meetings"] == nil)
    }

    @Test func meetingsOnAFreshProfileNeedTheSpeechModelAndSystemAudioIsNotCounted() async throws {
        defer { env.tearDown() }
        // The microphone macOS has not asked about (a fixed authorizer, not this process's real answer) and the
        // missing speech model; System Audio Recording cannot be read.
        let reader = FakePermissionsReader()
        let plugin = MeetingsPlugin(
            context: BannerContext.make(env, MeetingsPlugin.manifest, reader: reader),
            authorizer: FixedMicrophone(.notDetermined))
        try await plugin.activate()
        let banner = try #require(BannerContext.banner(plugin, reader: reader))
        #expect(banner.level == .attention)
        // The speaker model is missing too and never counted, and System Audio Recording never shows.
        #expect(banner.title == "2 things to do")
        #expect(!(banner.title + (banner.detail ?? "")).contains("System Audio"))
        await plugin.deactivate()
    }

    @Test func aDeniedMicrophoneIsCountedWithTheMissingModel() async throws {
        defer { env.tearDown() }
        let reader = FakePermissionsReader()
        reader.answers[.microphone] = .denied
        let plugin = MeetingsPlugin(
            context: BannerContext.make(env, MeetingsPlugin.manifest, reader: reader),
            authorizer: FixedMicrophone(.denied))
        try await plugin.activate()
        let banner = try #require(BannerContext.banner(plugin, reader: reader))
        // The model (the plugin's) and the microphone (the shell's line): two problems, two listed.
        #expect(banner.title == "2 things to do")
        #expect(banner.detail?.contains("The speech model isn’t installed.") == true)
        #expect(banner.detail?.contains("Microphone: not allowed") == true)
        await plugin.deactivate()
    }
}
