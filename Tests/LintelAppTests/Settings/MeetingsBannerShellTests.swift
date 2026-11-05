import Foundation
import LintelKit
import MeetingsPlugin
import Testing

@testable import LintelApp

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
        let host = env.makeHost([MeetingsPlugin.self])
        await host.start()
        await host.setEnabled(true, for: "meetings")
        // System Audio Recording cannot be read and the microphone has not been answered (the fake reader).
        let model = SettingsHostModel(host: host, reader: FakePermissionsReader())
        model.show("meetings")
        let banner = try #require(model.banner)
        #expect(banner.level == .attention)
        // "2 things to do" while macOS has not asked for this process's microphone, else "1 thing to do"; the
        // speaker model is missing too and never counted, and System Audio Recording never shows.
        #expect(["2 things to do", "1 thing to do"].contains(banner.title))
        #expect(!(banner.title + (banner.detail ?? "")).contains("System Audio"))
        #expect(model.attention["meetings"] == .attention)
        await host.setEnabled(false, for: "meetings")
    }
}
