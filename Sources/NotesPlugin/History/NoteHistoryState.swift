import Foundation
import LintelKit

/// What the store holds for the history of one layer document. Revision bodies are note text: kept in memory for
/// Compare, never logged.
struct HistorySnapshot: Sendable, Equatable {
    var docID: Int64
    var layer: String
    var headID: Int64
    var revisions: [RevisionRecord]
    /// A detached overlay (its recording is gone) shows its history but is never written to.
    var isDetached: Bool

    var entries: [HistoryEntry] { NoteHistory.entries(from: revisions, headID: headID) }
}

/// The inspector's History for the layer on screen.
enum HistoryState: Equatable {
    /// Not asked for yet (the History tab was never shown).
    case idle
    case loading
    /// The layer has no overlay: nothing was changed, so there is no history.
    case none
    case loaded(HistorySnapshot)
    case failed
}

/// The inline Compare on screen (prototype `diffDoc`): the older revision to the newer one.
struct CompareState: Equatable {
    var layer: String
    var revisionID: Int64
    var baseAuthor: NoteAuthor
    var baseDate: Date
    var author: NoteAuthor
    var date: Date
    var result: NoteDiff.Result
}

enum NoteInspectorTab: Equatable {
    case comments
    case history
    case details
}
