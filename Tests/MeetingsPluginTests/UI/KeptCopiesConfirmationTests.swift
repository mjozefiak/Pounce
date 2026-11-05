import Foundation
import LintelUI
import Testing

@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 5.3 (owner decision L1-39): Clear Library in the main window says
/// that copies edited or commented on in Notes stay and offers "Also delete kept copies", off by default; in
/// DEBUG only until Notes ships, and never in the old window.
@MainActor
@Suite struct MeetingsKeptCopiesConfirmationTests {
    @Test func clearLibraryInTheMainWindowHasTheNotesSentenceAndAnUncheckedBox() throws {
        let confirmation = MeetingsConfirmations.clearLibraryInMainWindow
        let option = try #require(confirmation.option(in: .mainWindow))
        #expect(option.title.key == "Also delete kept copies")
        #expect(option.explanation?.key.contains("Notes") == true)
        #expect(option.isOnByDefault == false)
        #expect(confirmation.prompt.key == MeetingsConfirmations.clearLibrary.prompt.key)
        #expect(confirmation.confirmTitle.key == "Delete All Meetings")
    }

    @Test func theOldWindowAndTheOtherActionsHaveNoCheckbox() {
        #expect(MeetingsConfirmations.clearLibraryInMainWindow.option(in: .legacyWindow) == nil)
        #expect(MeetingsConfirmations.clearLibrary.option == nil)
        #expect(MeetingsConfirmations.deleteRecordings.option == nil)
        #expect(MeetingsConfirmations.olderMeetings(count: 2).option == nil)
    }

    @Test func theCheckboxIsGuardedAndThePaneHandsItsStateToTheAction() throws {
        let pane = try String(
            contentsOf: TestPaths.meetingsSources.appending(path: "UI/MeetingsSettingsPane.swift"), encoding: .utf8)
        let legacy = try String(
            contentsOf: TestPaths.meetingsSources.appending(path: "UI/LegacyMeetingsSettingsPane.swift"),
            encoding: .utf8)
        #expect(pane.contains("model.clearLibrary(alsoDeleteKeptCopies: alsoDeleteKeptCopies)"))
        // Release builds keep today's words until Notes ships (spec B step 7.1 removes the guard).
        let guarded = try #require(pane.range(of: "#if DEBUG\n        clearLibrary.with(option: .keptNotesCopies)"))
        let release = try #require(pane.range(of: "#else\n        clearLibrary\n        #endif"))
        #expect(guarded.upperBound <= release.lowerBound)
        #expect(!legacy.contains("keptNotesCopies") && !legacy.contains("clearLibraryInMainWindow"))
    }

    @Test func clearingWithTheFlagStillWorksOnAnEmptyLibrary() throws {
        let rig = try SettingsRig()
        rig.library.open()
        rig.model.clearLibrary(alsoDeleteKeptCopies: true)
        #expect(rig.library.meetingCount == 0)
        #expect(!rig.model.privacyFailed)
        rig.library.close()
    }
}
