#if DEBUG
import Foundation
import Testing

@testable import LintelApp
@testable import LintelKit

@Suite struct QAHUDOptionsTests {
    @Test func hudTakesAPluginAndAState() throws {
        let dictation = try #require(try QAOptions.parse(["--qa-hud", "dictation:pasted"])?.hud)
        #expect(dictation.pluginID == "dictation")
        #expect(dictation.state == "pasted")
        let meeting = try #require(try QAOptions.parse(["--qa-hud", "meeting:recording-consent"])?.hud)
        #expect(meeting.pluginID == "meetings")
        #expect(meeting.state == "recording-consent")
        #expect(try QAOptions.parse(["--qa"])?.hud == nil)
    }

    @Test func hudRefusesAMissingOrUnknownRequest() {
        #expect(throws: QAOptions.ParseError.missingValue("--qa-hud")) { try QAOptions.parse(["--qa-hud"]) }
        for bad in ["pasted", "dictation:", ":pasted", "notes:pasted", "windows:x"] {
            #expect(throws: QAOptions.ParseError.invalidValue("--qa-hud", bad)) {
                try QAOptions.parse(["--qa-hud", bad])
            }
        }
    }

    @Test func hudSwitchesThePluginOnAndGivesItTheState() throws {
        let request = try #require(QAHUDRequest("meeting:finishing"))
        let seeded = AppEnvironment.qaHUDSettings(["plugins.x": .bool(true)], hud: request)
        #expect(seeded["plugins.meetings.enabled"] == .bool(true))
        #expect(seeded["plugins.meetings.qaHUD"] == .string("finishing"))
        #expect(seeded["plugins.x"] == .bool(true))
        #expect(AppEnvironment.qaHUDSettings(["a": .bool(true)], hud: nil) == ["a": .bool(true)])
    }

    // Issue #222: a QA run shows invented identity values, never the tester's.
    @Test func aQARunSeedsAnInventedNameAndAPathOutsideEveryHomeFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "lintel-qa-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = try AppEnvironment.qa(QAOptions(dataRoot: root))
        let name = environment.settings.value(forKey: QAOptions.meetingsAccountNameKey)
        let binary = environment.settings.value(forKey: QAOptions.meetingsProviderBinaryKey)
        #expect(name == .string(AppEnvironment.qaAccountName))
        #expect(binary == .string(AppEnvironment.qaProviderBinaryPath))
        #expect(AppEnvironment.qaAccountName != NSFullUserName())
        #expect(!AppEnvironment.qaProviderBinaryPath.hasPrefix(NSHomeDirectory()))
        #expect(!AppEnvironment.qaProviderBinaryPath.hasPrefix("/Users/"))
    }

    @Test func anExplicitQASettingWinsOverTheInventedIdentity() {
        let seeded = AppEnvironment.qaIdentitySettings([
            QAOptions.meetingsAccountNameKey: .string("Zed Test"),
            QAOptions.meetingsProviderBinaryKey: .string("/opt/other/claude"),
        ])
        #expect(seeded[QAOptions.meetingsAccountNameKey] == .string("Zed Test"))
        #expect(seeded[QAOptions.meetingsProviderBinaryKey] == .string("/opt/other/claude"))
    }
}
#endif
