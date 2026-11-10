import SwiftUI
import UniformTypeIdentifiers

extension NotesWorkspaceModel {
    /// A drag of tab `dragged` is over tab `target`: the dragged one takes that place.
    @discardableResult
    func reorderTab(_ dragged: NoteItemID, over target: NoteItemID) -> Bool {
        guard dragged != target, let index = tabs.index(of: target) else { return false }
        return moveTab(dragged, toIndex: index)
    }

    func canMoveTab(_ id: NoteItemID, by offset: Int) -> Bool {
        guard let index = tabs.index(of: id) else { return false }
        return tabs.tabs.indices.contains(index + offset)
    }
}

enum NoteTabDrag {
    /// Private to Lintel: dragging a tab never offers text or files to other apps.
    static let type = UTType(importedAs: "app.lintel.notes-tab", conformingTo: .data)
}

/// Drop target of one tab: while a tab of this bar is dragged over it, the dragged tab takes its place.
struct NoteTabDropDelegate: DropDelegate {
    let model: NotesWorkspaceModel
    let target: NoteItemID
    @Binding var dragged: NoteItemID?

    func validateDrop(info: DropInfo) -> Bool {
        dragged != nil && info.hasItemsConforming(to: [NoteTabDrag.type])
    }

    func dropEntered(info: DropInfo) {
        guard let dragged else { return }
        model.reorderTab(dragged, over: target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}
