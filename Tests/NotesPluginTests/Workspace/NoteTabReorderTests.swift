import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private func id(_ name: String) -> NoteItemID { .live(Fixtures.key("meetings", name)) }

private func tabs(_ names: [String], current: String? = nil) -> NoteTabSet {
    var set = NoteTabSet()
    for name in names {
        set.open(NoteTab(id: id(name), kind: .meeting, title: name.uppercased()))
    }
    if let current { set.select(id(current)) }
    return set
}

private func order(_ set: NoteTabSet) -> [String] { set.tabs.map(\.title) }

@Suite("Notes tab reorder (pure)")
struct NoteTabSetMoveTests {
    @Test("a tab moves forward and backward to the place asked for")
    func moves() {
        var set = tabs(["a", "b", "c", "d"])
        let moved8959 = set.move(id("a"), toIndex: 2)
        #expect(moved8959)
        #expect(order(set) == ["B", "C", "A", "D"])
        let moved2053 = set.move(id("d"), toIndex: 0)
        #expect(moved2053)
        #expect(order(set) == ["D", "B", "C", "A"])
    }

    @Test("the same index, an index outside the bar and an unknown tab change nothing")
    func edgeCases() {
        var set = tabs(["a", "b", "c"])
        let before = set
        let moved4820 = set.move(id("b"), toIndex: 1)
        #expect(!moved4820)
        let moved1087 = set.move(id("b"), toIndex: -1)
        #expect(!moved1087)
        let moved8414 = set.move(id("b"), toIndex: 3)
        #expect(!moved8414)
        let moved4851 = set.move(id("zzz"), toIndex: 0)
        #expect(!moved4851)
        let moved267 = set.move(id("a"), by: -1)
        #expect(!moved267)
        let moved725 = set.move(id("c"), by: 1)
        #expect(!moved725)
        #expect(set == before)
    }

    @Test("a single tab cannot move")
    func single() {
        var set = tabs(["a"])
        let moved4149 = set.move(id("a"), toIndex: 0)
        #expect(!moved4149)
        let moved8576 = set.move(id("a"), by: 1)
        #expect(!moved8576)
        #expect(order(set) == ["A"])
    }

    @Test("the current tab stays current whichever tab moves")
    func currentStays() {
        var set = tabs(["a", "b", "c"], current: "b")
        set.move(id("a"), toIndex: 2)
        #expect(set.current == id("b"))
        set.move(id("b"), toIndex: 0)
        #expect(set.current == id("b"))
        #expect(order(set) == ["B", "C", "A"])
    }

    @Test("moving by an offset moves one place at a time")
    func byOffset() {
        var set = tabs(["a", "b", "c"])
        let moved9053 = set.move(id("c"), by: -1)
        #expect(moved9053)
        #expect(order(set) == ["A", "C", "B"])
        let moved1512 = set.move(id("a"), by: 2)
        #expect(moved1512)
        #expect(order(set) == ["C", "B", "A"])
    }
}

@MainActor
@Suite("Notes tab reorder (model)")
struct NoteTabReorderModelTests {
    private func model(_ names: [String]) -> NotesWorkspaceModel {
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: SourceBox([])), pasteboard: RecordingPasteboard()))
        for name in names { model.open(id(name)) }
        return model
    }

    @Test("dragging a tab over another takes its place; dropping on itself does nothing")
    func dragOver() {
        let model = model(["a", "b", "c"])
        #expect(model.reorderTab(id("a"), over: id("c")))
        #expect(model.tabs.tabs.map(\.id) == [id("b"), id("c"), id("a")])
        #expect(!model.reorderTab(id("a"), over: id("a")))
        #expect(!model.reorderTab(id("a"), over: id("zzz")))
        #expect(model.currentID == id("c"))
    }

    @Test("Move Left and Move Right are offered only where the tab can move, and the middle tab has both")
    func accessibility() {
        let model = model(["a", "b", "c"])
        #expect(!model.canMoveTab(id("a"), by: -1) && model.canMoveTab(id("a"), by: 1))
        #expect(model.canMoveTab(id("b"), by: -1) && model.canMoveTab(id("b"), by: 1))
        #expect(model.canMoveTab(id("c"), by: -1) && !model.canMoveTab(id("c"), by: 1))
        #expect(model.moveTab(id("b"), by: 1))
        #expect(model.tabs.tabs.map(\.id) == [id("a"), id("c"), id("b")])
        #expect(!model.canMoveTab(id("zzz"), by: 1))
    }

    @Test("a moved tab still closes with a middle click and keeps its document")
    func stillClosable() {
        let model = model(["a", "b"])
        model.moveTab(id("a"), by: 1)
        #expect(model.documents[id("a")] != nil)
        #expect(model.handleTabOtherMouseUp(id("a"), buttonNumber: 2))
        #expect(model.tabs.tabs.map(\.id) == [id("b")])
    }
}
