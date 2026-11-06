import Foundation
import GRDB
import LintelKit

/// One `note_doc` row as the writers read it.
struct DocumentRecord: Sendable, Equatable {
    var id: Int64
    var key: NoteKey
    var layer: String
    var kind: NoteKind
    var sourcePluginID: PluginID
    var sourceState: NoteSourceState?
    var sourceStartedAtMs: Int64?
    var sourceVersionSeen: String?
    var headRevisionID: Int64
}

/// One `note_revision` row. Holds text: never logged.
struct RevisionRecord: Sendable, Equatable {
    var id: Int64
    var docID: Int64
    var seq: Int
    var author: String
    var state: NoteRevisionState
    var createdAt: Date
    var summary: String?
    var body: String
    var blocksJSON: String?
    var metaJSON: String?
}

/// A live row that a detach moved: what the registry needs to re-key an open document.
struct DetachedRow: Sendable, Equatable {
    var docID: Int64
    var layer: String
    var startedAtMs: Int64?
}

extension NotesStore {
    /// The revisions a document keeps at most (spec "Data Model"); older ones are pruned.
    static let revisionCap = 200

    private static let documentColumns = """
        id, key, layer, kind, source_plugin_id, source_state, source_started_at_ms, source_version_seen,
        head_revision_id
        """

    private static func documentRecord(_ row: Row) -> DocumentRecord? {
        let rawKey: String = row["key"]
        guard let key = NoteKey(rawValue: rawKey) else { return nil }
        let state: String? = row["source_state"]
        return DocumentRecord(
            id: row["id"], key: key, layer: row["layer"], kind: NoteKind(rawValue: row["kind"]),
            sourcePluginID: PluginID(rawValue: row["source_plugin_id"]),
            sourceState: state.flatMap(NoteSourceState.init), sourceStartedAtMs: row["source_started_at_ms"],
            sourceVersionSeen: row["source_version_seen"], headRevisionID: row["head_revision_id"])
    }

    private static let revisionColumns = """
        id, doc_id, seq, author, state, created_at, summary, body_markdown, blocks_json, meta_json
        """

    private static func revisionRecord(_ row: Row) -> RevisionRecord? {
        let state: String = row["state"]
        guard let parsed = NoteRevisionState(rawValue: state) else { return nil }
        return RevisionRecord(
            id: row["id"], docID: row["doc_id"], seq: row["seq"], author: row["author"], state: parsed,
            createdAt: Date(timeIntervalSince1970: row["created_at"]), summary: row["summary"],
            body: row["body_markdown"], blocksJSON: row["blocks_json"], metaJSON: row["meta_json"])
    }

    // MARK: Reads

    func document(id: Int64) throws -> DocumentRecord? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT \(Self.documentColumns) FROM note_doc WHERE id = ?", arguments: [id])
                .flatMap(Self.documentRecord)
        }
    }

    /// The live (not detached) document of a layer.
    func liveDocument(key: NoteKey, layer: String) throws -> DocumentRecord? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.documentColumns) FROM note_doc
                    WHERE key = ? AND layer = ? AND source_state IS NOT 'detached'
                    """, arguments: [key.rawValue, layer]
            ).flatMap(Self.documentRecord)
        }
    }

    func liveDocuments(key: NoteKey) throws -> [DocumentRecord] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.documentColumns) FROM note_doc
                    WHERE key = ? AND source_state IS NOT 'detached' ORDER BY id
                    """, arguments: [key.rawValue]
            ).compactMap(Self.documentRecord)
        }
    }

    /// The detached documents of one original recording (the key and the start time it was written against).
    func detachedDocuments(key: NoteKey, startedAtMs: Int64) throws -> [DocumentRecord] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT \(Self.documentColumns) FROM note_doc
                    WHERE key = ? AND source_state = 'detached' AND source_started_at_ms IS ? ORDER BY id
                    """, arguments: [key.rawValue, startedAtMs]
            ).compactMap(Self.documentRecord)
        }
    }

    func revision(id: Int64) throws -> RevisionRecord? {
        try read { db in
            try Row.fetchOne(
                db, sql: "SELECT \(Self.revisionColumns) FROM note_revision WHERE id = ?", arguments: [id]
            ).flatMap(Self.revisionRecord)
        }
    }

    func headRevision(of docID: Int64) throws -> RevisionRecord? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT \(Self.revisionColumns) FROM note_revision
                    WHERE id = (SELECT head_revision_id FROM note_doc WHERE id = ?)
                    """, arguments: [docID]
            ).flatMap(Self.revisionRecord)
        }
    }

    /// Every revision of a document, oldest first.
    func revisions(of docID: Int64) throws -> [RevisionRecord] {
        try read { db in
            try Row.fetchAll(
                db, sql: "SELECT \(Self.revisionColumns) FROM note_revision WHERE doc_id = ? ORDER BY seq",
                arguments: [docID]
            ).compactMap(Self.revisionRecord)
        }
    }

    /// The one definition of user writing, for one document.
    func hasUserWriting(_ docID: Int64) throws -> Bool {
        try read { db in try Self.hasUserWriting(docID, in: db) }
    }

    static func hasUserWriting(_ docID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM note_revision r WHERE r.doc_id = ?
                    AND ((r.state = 'applied' AND r.author = 'human')
                        OR (r.state = 'proposed' AND r.author = 'human')
                        OR (r.state = 'applied' AND r.author = 'agent' AND CASE WHEN json_valid(r.meta_json)
                                THEN json_extract(r.meta_json, '$.comment_ids') END IS NOT NULL)))
                """, arguments: [docID]) ?? false
    }

    /// A comment anchored to the revision, or a `base_head_id` / `restored_from` that names it: it is never
    /// amended and never pruned away from under its reference.
    static func isReferenced(_ revisionID: Int64, docID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS (SELECT 1 FROM note_comment WHERE anchor_revision_id = ?)
                    OR EXISTS (SELECT 1 FROM note_revision
                        WHERE doc_id = ? AND json_valid(meta_json)
                            AND (json_extract(meta_json, '$.base_head_id') = ?
                                OR json_extract(meta_json, '$.restored_from') = ?))
                """, arguments: [revisionID, docID, revisionID, revisionID]) ?? false
    }

    func isReferenced(_ revisionID: Int64, docID: Int64) throws -> Bool {
        try read { db in try Self.isReferenced(revisionID, docID: docID, in: db) }
    }

    // MARK: Writes

    /// Inserts the document with its seed revision and, in the SAME transaction, the first `human` revision on
    /// top of it. Nothing is written when either insert fails.
    func insertSeededDocument(_ seed: NewNoteDocument, human: NewNoteRevision) throws -> (
        docID: Int64, seedID: Int64, humanID: Int64
    ) {
        try write { db in
            let seeded = try Self.insertDocument(seed, in: db)
            var revision = human
            revision.docID = seeded.docID
            revision.expectedHeadID = seeded.revisionID
            let humanID = try Self.appendRevision(revision, in: db)
            return (seeded.docID, seeded.revisionID, humanID)
        }
    }

    /// Rewrites the head revision of an edit session in place. Returns `false`, changing nothing, when the head is
    /// no longer that revision, is not an applied `human` one, or is referenced (a comment anchor,
    /// `base_head_id`, `restored_from`): the caller then appends a new revision. The head moves nowhere, the FTS
    /// row is refreshed by the trigger.
    @discardableResult
    func amendHead(docID: Int64, revisionID: Int64, body: String, blocksJSON: String?, now: Date) throws -> Bool {
        try write { db in
            guard
                try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS (SELECT 1 FROM note_revision r JOIN note_doc d ON d.head_revision_id = r.id
                            WHERE d.id = ? AND r.id = ? AND r.author = 'human' AND r.state = 'applied')
                        """, arguments: [docID, revisionID]) == true,
                try !Self.isReferenced(revisionID, docID: docID, in: db)
            else { return false }
            try db.execute(
                sql: "UPDATE note_revision SET body_markdown = ?, blocks_json = ?, created_at = ? WHERE id = ?",
                arguments: [body, blocksJSON, now.timeIntervalSince1970, revisionID])
            try db.execute(
                sql: "UPDATE note_doc SET updated_at = ? WHERE id = ?", arguments: [now.timeIntervalSince1970, docID])
            return true
        }
    }

    /// Rewrites the `proposed` human revision that holds the text kept after a compare-and-set loss, so one
    /// conflict is one proposal however long the user keeps typing. Never touches the head.
    @discardableResult
    func amendProposal(docID: Int64, revisionID: Int64, body: String, blocksJSON: String?, now: Date) throws -> Bool {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE note_revision SET body_markdown = ?, blocks_json = ?, created_at = ?
                    WHERE id = ? AND doc_id = ? AND author = 'human' AND state = 'proposed'
                    """, arguments: [body, blocksJSON, now.timeIntervalSince1970, revisionID, docID])
            return db.changesCount > 0
        }
    }

    /// Apply: a `proposed` revision becomes the head as a NEW `applied` revision (its author, text and block authors,
    /// `applied_from` and `base_head_id` in its meta), and the proposal is set to `discarded` so History lists the
    /// text once. One transaction, with compare-and-set on the head: when the head is not `expectedHeadID` nothing
    /// is written and `casConflict` is thrown. Throws `guardRejected("proposalTarget")` when the revision is not a
    /// proposal of this document.
    func applyProposal(
        docID: Int64, proposalID: Int64, expectedHeadID: Int64, summary: String?, blocksJSON: String?,
        metaJSON: String?, now: Date
    ) throws -> Int64 {
        try write { db in
            guard
                let proposal = try Row.fetchOne(
                    db,
                    sql:
                        "SELECT author, body_markdown FROM note_revision WHERE id = ? AND doc_id = ? AND state = 'proposed'",
                    arguments: [proposalID, docID])
            else { throw NotesError.guardRejected(rule: "proposalTarget") }
            let author: String = proposal["author"]
            let body: String = proposal["body_markdown"]
            let id = try Self.appendRevision(
                NewNoteRevision(
                    docID: docID, author: author, state: .applied, body: body, summary: summary,
                    blocksJSON: blocksJSON, metaJSON: metaJSON, now: now, expectedHeadID: expectedHeadID),
                in: db)
            try db.execute(
                sql:
                    "UPDATE note_revision SET state = 'discarded', meta_json = \(Self.markResolvedSQL) WHERE id = ? AND doc_id = ?",
                arguments: [proposalID, docID])
            return id
        }
    }

    /// `meta_json` with `"resolved": 1`: the user decided about this proposal (applied, or confirmed its removal),
    /// so `prune` may take it. A `discarded` proposal of the user's own text without it is never pruned.
    static let markResolvedSQL =
        "CASE WHEN json_valid(meta_json) AND json_type(meta_json) = 'object' THEN json_set(meta_json, '$.resolved', 1) ELSE '{\"resolved\":1}' END"

    /// Discard: the proposal is hidden from History and never applied; the row stays. A proposal that holds the user's
    /// own text (`human`, kept after a compare-and-set loss) is removed only with `confirmedRemoval`: without it
    /// `guardRejected("discardNeedsConfirmation")` is thrown and nothing changes. Such a row is kept by `prune`
    /// until the confirmation is recorded in its meta. `false` when the revision is not a proposal of this document.
    @discardableResult
    func discardProposal(docID: Int64, proposalID: Int64, confirmedRemoval: Bool = false) throws -> Bool {
        try write { db in
            let author = try String.fetchOne(
                db, sql: "SELECT author FROM note_revision WHERE id = ? AND doc_id = ? AND state = 'proposed'",
                arguments: [proposalID, docID])
            if author == "human", !confirmedRemoval {
                throw NotesError.guardRejected(rule: "discardNeedsConfirmation")
            }
            try db.execute(
                sql: """
                    UPDATE note_revision SET state = 'discarded', meta_json = \(Self.markResolvedSQL)
                    WHERE id = ? AND doc_id = ? AND state = 'proposed'
                    """,
                arguments: [proposalID, docID])
            return db.changesCount > 0
        }
    }

    /// Records the source layer version a document has been reconciled with, without a revision.
    func setSourceVersionSeen(docID: Int64, version: String) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE note_doc SET source_version_seen = ? WHERE id = ?", arguments: [version, docID])
        }
    }

    /// Like `detach`, and reports the rows it moved (with `alongside` in the same transaction), so the registry
    /// can re-key the open documents.
    @discardableResult
    func detachReportingRows(
        _ key: NoteKey, alongside: (Database, [DetachedRow]) throws -> Void = { _, _ in }
    ) throws -> [DetachedRow] {
        try writeMaintenance { db in
            let moved = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, layer, source_started_at_ms FROM note_doc
                    WHERE key = ? AND source_plugin_id != 'notes' AND source_state IS NOT 'detached' ORDER BY id
                    """, arguments: [key.rawValue]
            ).map { DetachedRow(docID: $0["id"], layer: $0["layer"], startedAtMs: $0["source_started_at_ms"]) }
            try db.execute(
                sql: """
                    UPDATE note_doc SET source_state = 'detached'
                    WHERE key = ? AND source_plugin_id != 'notes' AND source_state IS NOT 'detached'
                    """, arguments: [key.rawValue])
            try alongside(db, moved)
            return moved
        }
    }

    /// Documents Export All may write: every head except a `detached` row without user writing and without an
    /// open comment (that row is leftover, deleted as soon as it is not open).
    func exportableDocumentIDs() throws -> [Int64] {
        try exportRows().map(\.docID)
    }

    // MARK: Pruning

    /// Keeps a document at `cap` revisions: `discarded` ones first, then the oldest unreferenced applied `human`
    /// snapshots. Never pruned: the head, the first `stt`/`agent` revision, the last user-writing revision, a
    /// `proposed` revision, a `discarded` proposal of the user's own text whose removal was never confirmed and one a `base_head_id` / `restored_from` names. A comment anchored to a revision that
    /// goes is first re-anchored to the nearest kept revision (by sequence). Returns how many were removed.
    @discardableResult
    func prune(docID: Int64, cap: Int = NotesStore.revisionCap) throws -> Int {
        try write { db in
            struct Item {
                var id: Int64
                var seq: Int
                var author: String
                var state: String
                var userWriting: Bool
                var unconfirmed: Bool
            }
            let items = try Row.fetchAll(
                db,
                sql: """
                    SELECT r.id, r.seq, r.author, r.state,
                        (r.state = 'discarded' AND r.author = 'human' AND NOT (CASE WHEN json_valid(r.meta_json)
                            THEN COALESCE(json_extract(r.meta_json, '$.resolved'), 0) = 1 ELSE 0 END)) AS unconfirmed,
                        (r.state = 'applied' AND (r.author = 'human'
                            OR (r.author = 'agent' AND CASE WHEN json_valid(r.meta_json)
                                    THEN json_extract(r.meta_json, '$.comment_ids') END IS NOT NULL))) AS writing
                    FROM note_revision r WHERE r.doc_id = ? ORDER BY r.seq
                    """, arguments: [docID]
            ).map {
                Item(
                    id: $0["id"], seq: $0["seq"], author: $0["author"], state: $0["state"], userWriting: $0["writing"],
                    unconfirmed: $0["unconfirmed"])
            }
            let excess = items.count - cap
            guard excess > 0 else { return 0 }
            let headID = try Int64.fetchOne(
                db, sql: "SELECT head_revision_id FROM note_doc WHERE id = ?", arguments: [docID])
            var protected: Set<Int64> = []
            if let headID { protected.insert(headID) }
            if let first = items.first(where: { $0.author != "human" }) { protected.insert(first.id) }
            if let last = items.last(where: { $0.userWriting }) { protected.insert(last.id) }
            for item in items where item.state == "proposed" || item.unconfirmed { protected.insert(item.id) }
            let named = try Row.fetchAll(
                db,
                sql: """
                    SELECT json_extract(meta_json, '$.base_head_id') AS a, json_extract(meta_json, '$.restored_from') AS b
                    FROM note_revision WHERE doc_id = ? AND json_valid(meta_json)
                    """, arguments: [docID])
            for row in named {
                if let a: Int64 = row["a"] { protected.insert(a) }
                if let b: Int64 = row["b"] { protected.insert(b) }
            }
            let candidates =
                items.filter { $0.state == "discarded" && !protected.contains($0.id) }
                + items.filter { $0.state == "applied" && $0.author == "human" && !protected.contains($0.id) }
            let doomed = Array(candidates.prefix(excess))
            let doomedIDs = Set(doomed.map(\.id))
            let survivors = items.filter { !doomedIDs.contains($0.id) }
            for candidate in doomed {
                // Re-anchor first: the nearest revision that stays (by sequence, the later one on a tie).
                if let target = survivors.min(by: {
                    let a = abs($0.seq - candidate.seq)
                    let b = abs($1.seq - candidate.seq)
                    return a == b ? $0.seq > $1.seq : a < b
                }) {
                    try db.execute(
                        sql: "UPDATE note_comment SET anchor_revision_id = ? WHERE anchor_revision_id = ?",
                        arguments: [target.id, candidate.id])
                }
                try db.execute(sql: "DELETE FROM note_revision WHERE id = ?", arguments: [candidate.id])
            }
            let removed = doomed.count
            return removed
        }
    }
}
