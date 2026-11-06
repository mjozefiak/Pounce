#if DEBUG
import Foundation
import Testing

@testable import LintelApp

@Suite struct QAMeetingOptionsTests {
    @Test func parsesTheMeetingAudioFilesAndTheSpoolFolder() throws {
        let options = try #require(
            try QAOptions.parse([
                "Lintel", "--qa-meeting-mic-wav", "/tmp/mic.wav", "--qa-meeting-system-wav", "/tmp/system.wav",
                "--qa-meeting-spool-dir", "/tmp/spool",
            ])
        )
        #expect(options.meetingMicWAV?.path == "/tmp/mic.wav")
        #expect(options.meetingSystemWAV?.path == "/tmp/system.wav")
        #expect(options.meetingSpoolDirectory?.path == "/tmp/spool")
        #expect(try QAOptions.parse(["--qa"])?.meetingMicWAV == nil)
    }

    @Test func qaNotesTurnsOnTheFixturesKeyOnly() throws {
        #expect(try QAOptions.parse(["--qa-notes"])?.notesFixtures == true)
        #expect(try QAOptions.parse(["--qa"])?.notesFixtures == false)
        let on = AppEnvironment.qaNotesSettings(["plugins.x": .bool(true)], fixtures: true)
        #expect(on == ["plugins.x": .bool(true), QAOptions.notesFixturesKey: .bool(true)])
        #expect(AppEnvironment.qaNotesSettings([:], fixtures: false).isEmpty)
    }

    @Test func rejectsAMissingOrOptionLikeValue() {
        #expect(throws: QAOptions.ParseError.missingValue("--qa-meeting-mic-wav")) {
            _ = try QAOptions.parse(["--qa-meeting-mic-wav"])
        }
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-meeting-system-wav", "--qa")) {
            _ = try QAOptions.parse(["--qa-meeting-system-wav", "--qa"])
        }
    }
}
#endif
