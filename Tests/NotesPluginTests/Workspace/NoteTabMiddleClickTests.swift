import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite("Notes tab middle click")
struct NoteTabMiddleClickTests {
    private final class Cancelled { var ids: [NoteItemID] = [] }

    private func rig() -> (model: NotesWorkspaceModel, cancelled: Cancelled, a: NoteItemID, b: NoteItemID) {
        let cancelled = Cancelled()
        var environment = NotesWorkspaceModel.Environment(
            library: NoteLibrary(box: SourceBox([])), pasteboard: RecordingPasteboard())
        environment.cancelRevise = { cancelled.ids.append($0) }
        let model = NotesWorkspaceModel(environment: environment)
        let a = NoteItemID.live(Fixtures.key("meetings", "a"))
        let b = NoteItemID.live(Fixtures.key("meetings", "b"))
        model.open(a)
        model.open(b)
        return (model, cancelled, a, b)
    }

    @Test("only the middle button (number 2) closes")
    func buttons() {
        #expect(NoteTabMiddleClick.closes(buttonNumber: 2))
        for other in [0, 1, 3, 4, -1] { #expect(!NoteTabMiddleClick.closes(buttonNumber: other), "\(other)") }
    }

    @Test("a middle click closes that tab, not the current one, and the current tab stays current")
    func closesTheClickedTab() {
        let rig = rig()
        #expect(rig.model.currentID == rig.b)
        #expect(rig.model.handleTabOtherMouseUp(rig.a, buttonNumber: 2))
        #expect(rig.model.tabs.tabs.map(\.id) == [rig.b])
        #expect(rig.model.currentID == rig.b)
        #expect(rig.model.documents[rig.a] == nil)
    }

    @Test("it does what the close button does: the same state, and a run for the note is cancelled")
    func sameAsTheCloseButton() {
        let viaButton = rig()
        viaButton.model.close(viaButton.b)
        let viaMiddle = rig()
        #expect(viaMiddle.model.handleTabOtherMouseUp(viaMiddle.b, buttonNumber: 2))
        #expect(viaMiddle.model.tabs.tabs.map(\.id) == viaButton.model.tabs.tabs.map(\.id))
        #expect(viaMiddle.model.currentID == viaButton.model.currentID)
        #expect(viaMiddle.cancelled.ids == [viaMiddle.b])
        #expect(viaButton.cancelled.ids == [viaButton.b])
    }

    @Test("other buttons and unknown tabs change nothing")
    func ignored() {
        let rig = rig()
        #expect(!rig.model.handleTabOtherMouseUp(rig.a, buttonNumber: 0))
        #expect(!rig.model.handleTabOtherMouseUp(rig.a, buttonNumber: 1))
        #expect(!rig.model.handleTabOtherMouseUp(.live(Fixtures.key("meetings", "zzz")), buttonNumber: 2))
        #expect(rig.model.tabs.tabs.count == 2)
        #expect(rig.cancelled.ids.isEmpty)
    }

    @Test("a middle click on the last tab leaves no tab")
    func lastTab() {
        let rig = rig()
        rig.model.handleTabOtherMouseUp(rig.a, buttonNumber: 2)
        rig.model.handleTabOtherMouseUp(rig.b, buttonNumber: 2)
        #expect(rig.model.tabs.tabs.isEmpty)
        #expect(rig.model.currentID == nil)
    }
}
