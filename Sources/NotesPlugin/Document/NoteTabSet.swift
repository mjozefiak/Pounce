import Foundation
import LintelKit

/// One open note. Identity is the `NoteItemID`, so a note has one tab whichever layer (notes or transcript) it
/// shows.
struct NoteTab: Identifiable, Equatable, Sendable {
    var id: NoteItemID
    var kind: NoteKind
    /// The row's title at the time; the tab bar masks it while content is hidden (step 7.x).
    var title: String
    /// A source is still working on the note (writing notes, processing): the tab shows a spinner.
    var isBusy = false
}

/// The tab bar's state, pure: tabs in opening order and the current one.
struct NoteTabSet: Equatable, Sendable {
    private(set) var tabs: [NoteTab] = []
    private(set) var current: NoteItemID?

    /// Opens a tab, or selects the one the note already has. Returns `true` when a new tab was added.
    @discardableResult
    mutating func open(_ tab: NoteTab) -> Bool {
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index].title = tab.title
            tabs[index].isBusy = tab.isBusy
            current = tab.id
            return false
        }
        tabs.append(tab)
        current = tab.id
        return true
    }

    mutating func select(_ id: NoteItemID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        current = id
    }

    /// Closes a tab. When it was the current one the neighbour to its right is shown, else the one to its left.
    mutating func close(_ id: NoteItemID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        guard current == id else { return }
        current = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }

    /// Moves a tab so that it ends up at `index` (the others shift by one); the current tab stays current. Returns
    /// `false`, and changes nothing, for an unknown tab, an index outside the tabs or the place it already has.
    @discardableResult
    mutating func move(_ id: NoteItemID, toIndex index: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == id }), tabs.indices.contains(index), from != index else {
            return false
        }
        tabs.insert(tabs.remove(at: from), at: index)
        return true
    }

    /// Moves a tab by `offset` places (negative: to the left). `false` when it would leave the bar.
    @discardableResult
    mutating func move(_ id: NoteItemID, by offset: Int) -> Bool {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return move(id, toIndex: from + offset)
    }

    func index(of id: NoteItemID) -> Int? { tabs.firstIndex { $0.id == id } }

    mutating func update(_ id: NoteItemID, title: String, isBusy: Bool) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].title = title
        tabs[index].isBusy = isBusy
    }

    /// A detach changed what the tab names (`.live(key)` to `.detached(key, startedAtMs:)`): the tab keeps its
    /// place and selection. Returns `false` when there was no such tab or the new identity already has one.
    @discardableResult
    mutating func rekey(from old: NoteItemID, to new: NoteItemID, title: String? = nil) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == old }), !tabs.contains(where: { $0.id == new }) else {
            return false
        }
        tabs[index].id = new
        if let title { tabs[index].title = title }
        if current == old { current = new }
        return true
    }

    func contains(_ id: NoteItemID) -> Bool { tabs.contains { $0.id == id } }
}
