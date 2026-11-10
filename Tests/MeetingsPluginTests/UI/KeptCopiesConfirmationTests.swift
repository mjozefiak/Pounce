import Foundation
import LintelUI
import Testing

@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 5.3 (owner decision L1-39): Clear Library says that copies edited
/// or commented on in Notes stay and offers "Also delete kept copies", off by default; in every build since Notes was
/// enabled (step 7.1).
@MainActor
@Suite struct MeetingsKeptCopiesConfirmationTests {
    @Test func clearLibraryHasTheNotesSentenceAndAnUncheckedBox() throws {
        let confirmation = MeetingsConfirmations.clearLibraryInMainWindow(keptCopies: 3)
        let option = try #require(confirmation.option)
        #expect(option.title.key == "Also delete kept copies")
        #expect(option.explanation?.key.contains("Notes") == true)
        #expect(option.isOnByDefault == false)
        #expect(confirmation.prompt.key == MeetingsConfirmations.clearLibrary.prompt.key)
        #expect(confirmation.confirmTitle.key == "Delete All Meetings")
    }

    @Test func withoutKeptCopiesTheSheetHasNoCheckbox() {
        #expect(MeetingsConfirmations.clearLibraryInMainWindow(keptCopies: 0).option == nil)
    }

    @Test func theOtherActionsHaveNoCheckbox() {
        #expect(MeetingsConfirmations.clearLibrary.option == nil)
        #expect(MeetingsConfirmations.deleteRecordings.option == nil)
        #expect(MeetingsConfirmations.olderMeetings(count: 2).option == nil)
    }

    @Test func theCheckboxIsInEveryBuildAndThePaneHandsItsStateToTheAction() throws {
        let pane = try String(
            contentsOf: TestPaths.meetingsSources.appending(path: "UI/MeetingsSettingsPane.swift"), encoding: .utf8)
        #expect(pane.contains("model.clearLibrary(alsoDeleteKeptCopies: alsoDeleteKeptCopies)"))
        // Notes is enabled (spec B step 7.1): the sentence is not behind `#if DEBUG` any more.
        #expect(pane.contains(".keptNotesCopies(count: keptCopies)"))
        #expect(!pane.contains("#if DEBUG"))
    }

    @Test func clearingWithTheFlagStillWorksOnAnEmptyLibrary() async throws {
        let rig = try SettingsRig()
        rig.library.open()
        await rig.model.clearLibrary(alsoDeleteKeptCopies: true)?.value
        #expect(rig.library.meetingCount == 0)
        #expect(!rig.model.privacyFailed)
        rig.library.close()
    }

    // MARK: Kept copies in Notes: only with the box, only after the library was cleared

    @Test func theCopiesAreDeletedOnlyWhenTheBoxIsTickedAndAfterTheLibraryWasCleared() async throws {
        let rig = try SettingsRig()
        rig.library.open()
        var order: [String] = []
        let library = rig.library
        rig.model.deleteKeptCopies = {
            order.append("copies after \(library.meetingCount) meetings")
            return true
        }
        rig.model.clearLibrary(alsoDeleteKeptCopies: false)
        #expect(order.isEmpty, "unticked: nothing in Notes is deleted")
        await rig.model.clearLibrary(alsoDeleteKeptCopies: true)?.value
        #expect(order == ["copies after 0 meetings"])
        rig.library.close()
    }

    @Test func aFailedCopyRemovalSaysSoAfterTheLibraryWasCleared() async throws {
        let rig = try SettingsRig()
        rig.library.open()
        rig.model.deleteKeptCopies = { false }
        await rig.model.clearLibrary(alsoDeleteKeptCopies: true)?.value
        #expect(rig.model.privacyFailed)
        rig.library.close()
    }

    @Test func theNumberOfKeptCopiesIsReadFromNotesBeforeTheSheetOpens() async throws {
        let rig = try SettingsRig()
        rig.model.keptCopies = { 4 }
        #expect(rig.model.keptCopyCount == 0)
        await rig.model.refreshKeptCopies()
        #expect(rig.model.keptCopyCount == 4)
    }
}
