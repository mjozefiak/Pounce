import Foundation
import LintelKit

/// History, Compare and Restore of the open note (step 4.5). History is read from `notes.sqlite` for the layer on
/// screen; Restore goes through the layer's one writer, so it flushes typed text first and moves the head with
/// compare-and-set like every other head-moving write.
extension NotesWorkspaceModel {
    /// The History tab is on screen, so writes elsewhere (a reload after editing) refresh it.
    var showsHistory: Bool { inspectorVisible && inspectorTab == .history }

    func refreshHistoryIfShown(_ id: NoteItemID) async {
        guard showsHistory else { return }
        await loadHistory(for: id)
    }

    /// Reads the history of the layer the document shows. A reload keeps the list on screen until the new one is in.
    func loadHistory(for id: NoteItemID) async {
        guard let document = documents[id], let layer = document.layerID else { return }
        if document.history == .idle { document.setHistory(.loading) }
        let state = await environment.loadHistory(id, layer)
        // The tab closed, or the document moved to another layer while the store was read.
        guard documents[id] === document, document.layerID == layer else { return }
        document.setHistory(state)
    }

    func selectInspectorTab(_ tab: NoteInspectorTab) {
        inspectorTab = tab
        if tab == .history, let id = currentID { Task { await loadHistory(for: id) } }
    }

    /// Whether Restore is offered: the store can be written and the document is not a detached overlay.
    func canRestore(_ document: NoteDocumentModel, _ snapshot: HistorySnapshot) -> Bool {
        environment.canEditNotes && !snapshot.isDetached
    }

    // MARK: Compare

    /// Compare: the revision against the applied one before it (a proposal: against the revision it would replace).
    func showCompare(revisionID: Int64) async {
        guard let id = currentID, let document = documents[id], case .loaded(let snapshot) = document.history,
            let revision = snapshot.revisions.first(where: { $0.id == revisionID }),
            let base = baseRevision(of: revision, in: snapshot)
        else { return }
        // The editor holds typed text the history does not know yet: write it, then leave it.
        if let session = document.session {
            await session.flush(closingSession: true)
            document.leaveEditing()
        }
        document.setCompare(
            CompareState(
                layer: snapshot.layer, revisionID: revisionID, baseAuthor: NoteAuthor(rawValue: base.author),
                baseDate: base.createdAt, author: NoteAuthor(rawValue: revision.author), date: revision.createdAt,
                result: NoteHistory.compare(revision, against: base)))
    }

    func closeCompare() {
        currentDocument?.setCompare(nil)
    }

    private func baseRevision(of revision: RevisionRecord, in snapshot: HistorySnapshot) -> RevisionRecord? {
        snapshot.revisions.filter { $0.seq < revision.seq && $0.state == .applied }.max { $0.seq < $1.seq }
    }

    /// The newest revision kept aside after a compare-and-set loss ("Your edits were kept as a proposal").
    func showProposalCompare() async {
        guard let id = currentID else { return }
        await loadHistory(for: id)
        guard let document = documents[id], case .loaded(let snapshot) = document.history,
            let proposal = snapshot.revisions.filter({ $0.state == .proposed }).max(by: { $0.seq < $1.seq })
        else { return }
        await showCompare(revisionID: proposal.id)
    }

    // MARK: Restore

    /// Restore: a NEW `human` revision with the text and authors of an earlier one, so nothing in the chain is
    /// lost. Typed text is written first (the writer flushes before it moves the head).
    func restore(revisionID: Int64) async {
        guard let id = currentID, let document = documents[id], let layer = document.layerID,
            case .loaded(let snapshot) = document.history, canRestore(document, snapshot),
            snapshot.revisions.contains(where: { $0.id == revisionID && $0.state == .applied })
        else { return }
        if let session = document.session {
            await session.flush(closingSession: true)
            document.leaveEditing()
        }
        document.setCompare(nil)
        let done = await environment.restoreRevision(id, layer, revisionID)
        show(done ? .restored : .restoreFailed)
        await loadContent(id)
        await loadHistory(for: id)
    }
}
