import Foundation
import LintelKit

/// One row of the inspector's History (prototype `.he`): who, when, what changed, and what can be done with it.
/// Holds no note text; the change is described by counts.
struct HistoryEntry: Identifiable, Equatable, Sendable {
    enum Change: Equatable, Sendable {
        /// The first revision of the layer: the text as the source wrote it (or a manual note's start).
        case original
        /// A later revision that changed `edited` blocks, added `added` and removed `removed`.
        case blocks(edited: Int, added: Int, removed: Int)
        /// Restore: a new revision with the text of an earlier one.
        case restored
        /// Kept aside, not applied (a proposal).
        case proposed
        /// Nothing differs from the revision before it.
        case unchanged
    }

    var id: Int64
    var author: NoteAuthor
    var createdAt: Date
    var change: Change
    var isHead: Bool
    var state: NoteRevisionState
    /// The revision it is compared with: the applied one before it; `nil` for the first. A proposal is compared with
    /// the head it would replace.
    var baseID: Int64?
    /// The text of an agent's own description (the model, the comments it answered), shown when present.
    var note: String?

    /// Restore turns an earlier applied revision into the head; the head itself and proposals are not offered.
    var canRestore: Bool { state == .applied && !isHead }
    var canCompare: Bool { baseID != nil || isProposal }
    /// Kept aside, waiting for Apply or Discard (step 6.3).
    var isProposal: Bool { state == .proposed }
}

enum NoteHistory {
    /// The revisions of a document as History lists them, newest first. `discarded` revisions are not listed.
    static func entries(from revisions: [RevisionRecord], headID: Int64) -> [HistoryEntry] {
        let ordered = revisions.sorted { $0.seq < $1.seq }
        var result: [HistoryEntry] = []
        var previousApplied: RevisionRecord?
        for revision in ordered {
            let base = previousApplied
            defer { if revision.state == .applied { previousApplied = revision } }
            guard revision.state != .discarded else { continue }
            let change: HistoryEntry.Change
            if let restored = NoteHistoryMeta.restoredFrom(revision.metaJSON), restored > 0 {
                change = .restored
            } else if revision.state == .proposed {
                change = .proposed
            } else if let base {
                let diff = NoteDiff.compare(old: base.body, oldAuthors: nil, new: revision.body, newAuthors: nil)
                change =
                    diff.isEmpty
                    ? .unchanged
                    : .blocks(
                        edited: diff.edited, added: diff.added - diff.edited, removed: diff.removed - diff.edited)
            } else {
                change = .original
            }
            result.append(
                HistoryEntry(
                    id: revision.id, author: NoteAuthor(rawValue: revision.author), createdAt: revision.createdAt,
                    change: change, isHead: revision.id == headID, state: revision.state,
                    baseID: revision.state == .proposed ? headID : base?.id, note: nil))
        }
        return result.reversed()
    }

    /// Compare for one revision against its base (`nil` base: the head, for a proposal).
    static func compare(_ revision: RevisionRecord, against base: RevisionRecord) -> NoteDiff.Result {
        NoteDiff.compare(
            old: base.body, oldAuthors: StoredBlocks.decode(base.blocksJSON)?.blocks.map(\.author),
            new: revision.body, newAuthors: StoredBlocks.decode(revision.blocksJSON)?.blocks.map(\.author))
    }
}

enum NoteHistoryMeta {
    static func restoredFrom(_ json: String?) -> Int64? {
        guard let data = json?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (object["restored_from"] as? NSNumber)?.int64Value
    }
}
