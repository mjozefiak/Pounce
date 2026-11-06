import Foundation
import GRDB
import LintelKit

/// A new document (a manual note, or an overlaid layer of a recorded note) with its first revision.
struct NewNoteDocument: Sendable {
    var key: NoteKey
    var layer: String
    var kind: NoteKind
    var sourcePluginID: PluginID
    var titleOverride: String?
    var sourceState: NoteSourceState?
    var sourceStartedAtMs: Int64?
    var sourceVersionSeen: String?
    var author: String
    var body: String
    var summary: String?
    var blocksJSON: String?
    var metaJSON: String?
    var now: Date
}

/// A revision appended to an existing document.
struct NewNoteRevision: Sendable {
    var docID: Int64
    var author: String
    var state: NoteRevisionState
    var body: String
    var summary: String?
    var blocksJSON: String?
    var metaJSON: String?
    var now: Date
    /// For an `applied` revision: the head the writer saw; the head moves only when it is still this one.
    var expectedHeadID: Int64?
}

extension NotesStore {
    /// The manual-note plugin id (`source_plugin_id` of a manual note).
    static let manualPluginID = PluginID(rawValue: "notes")

    /// Inserts the document and its first revision, and points the head at it, in one transaction.
    @discardableResult
    func insertDocument(_ document: NewNoteDocument) throws -> (docID: Int64, revisionID: Int64) {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO note_doc (key, layer, kind, source_plugin_id, title_override, head_revision_id,
                        created_at, updated_at, source_state, source_started_at_ms, source_version_seen)
                    VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    document.key.rawValue, document.layer, document.kind.rawValue, document.sourcePluginID.rawValue,
                    document.titleOverride, document.now.timeIntervalSince1970, document.now.timeIntervalSince1970,
                    document.sourceState?.rawValue, document.sourceStartedAtMs, document.sourceVersionSeen,
                ])
            let docID = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO note_revision (doc_id, seq, author, state, created_at, summary, body_markdown,
                        blocks_json, meta_json)
                    VALUES (?, 1, ?, 'applied', ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    docID, document.author, document.now.timeIntervalSince1970, document.summary, document.body,
                    document.blocksJSON, document.metaJSON,
                ])
            let revisionID = db.lastInsertedRowID
            try db.execute(
                sql: "UPDATE note_doc SET head_revision_id = ? WHERE id = ?", arguments: [revisionID, docID])
            return (docID, revisionID)
        }
    }

    /// Appends a revision. An `applied` one moves the head with compare-and-set, in the same transaction; when
    /// the head is no longer `expectedHeadID` nothing is written and `casConflict` is thrown. A `proposed` or
    /// `discarded` one never moves the head.
    @discardableResult
    func appendRevision(_ revision: NewNoteRevision) throws -> Int64 {
        try write { db in
            let seq =
                try Int.fetchOne(
                    db, sql: "SELECT COALESCE(MAX(seq), 0) + 1 FROM note_revision WHERE doc_id = ?",
                    arguments: [revision.docID]) ?? 1
            try db.execute(
                sql: """
                    INSERT INTO note_revision (doc_id, seq, author, state, created_at, summary, body_markdown,
                        blocks_json, meta_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    revision.docID, seq, revision.author, revision.state.rawValue,
                    revision.now.timeIntervalSince1970, revision.summary, revision.body, revision.blocksJSON,
                    revision.metaJSON,
                ])
            let id = db.lastInsertedRowID
            if revision.state == .applied {
                try db.execute(
                    sql: """
                        UPDATE note_doc SET head_revision_id = ?, updated_at = ?
                        WHERE id = ? AND head_revision_id = ?
                        """,
                    arguments: [id, revision.now.timeIntervalSince1970, revision.docID, revision.expectedHeadID])
                if db.changesCount != 1 { throw NotesError.casConflict }
            }
            return id
        }
    }

    func deleteDocument(_ id: Int64) throws {
        try write { db in try db.execute(sql: "DELETE FROM note_doc WHERE id = ?", arguments: [id]) }
    }

    /// Deletes every live overlay of a recorded note (after the source deleted it). Detached rows stay.
    @discardableResult
    func deleteLiveOverlays(of key: NoteKey) throws -> Int {
        try write { db in
            try db.execute(
                sql: "DELETE FROM note_doc WHERE key = ? AND source_state IS NOT 'detached'", arguments: [key.rawValue])
            return db.changesCount
        }
    }

    /// Moves every live row of the key to `detached` in ONE transaction together with `alongside` (the re-key
    /// of an open document, the pending-write bookkeeping): when that throws, nothing is detached.
    @discardableResult
    func detach(_ key: NoteKey, alongside: (Database) throws -> Void = { _ in }) throws -> Int {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE note_doc SET source_state = 'detached'
                    WHERE key = ? AND source_plugin_id != 'notes' AND source_state IS NOT 'detached'
                    """,
                arguments: [key.rawValue])
            let changed = db.changesCount
            try alongside(db)
            return changed
        }
    }

    /// The persistent rule: a `detached` row without user writing and without an open comment, and not open in
    /// the registry (`openDocIDs`), is deleted. Returns how many were deleted.
    @discardableResult
    func deleteUnkeptDetached(excluding openDocIDs: Set<Int64> = []) throws -> Int {
        try write { db in
            let ids = try Int64.fetchAll(
                db,
                sql: """
                    SELECT d.id FROM note_doc d WHERE d.source_state = 'detached' AND NOT \(Self.keptSQL)
                    """
            ).filter { !openDocIDs.contains($0) }
            for id in ids { try db.execute(sql: "DELETE FROM note_doc WHERE id = ?", arguments: [id]) }
            return ids.count
        }
    }

    /// User writing (an applied `human` revision, or an applied `agent` revision with `comment_ids`, one
    /// definition) or an open comment: the overlay is never deleted with its source.
    static let keptSQL = """
        (EXISTS (SELECT 1 FROM note_revision r WHERE r.doc_id = d.id AND r.state = 'applied'
                    AND (r.author = 'human'
                        OR (r.author = 'agent' AND json_extract(r.meta_json, '$.comment_ids') IS NOT NULL)))
            OR EXISTS (SELECT 1 FROM note_comment c WHERE c.doc_id = d.id AND c.status = 'open'))
        """
}

// MARK: - Overlay rows

extension NotesStore {
    private static let overlayColumns = """
        d.id, d.key, d.layer, d.kind, d.source_plugin_id, d.title_override, d.source_started_at_ms, d.created_at,
        d.updated_at, \(keptSQL) AS kept
        """

    private func overlayRecords(_ db: Database, where condition: String, arguments: StatementArguments)
        throws -> [OverlayRecord]
    {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT \(Self.overlayColumns) FROM note_doc d WHERE \(condition) ORDER BY d.id",
            arguments: arguments)
        return rows.compactMap { row -> OverlayRecord? in
            let rawKey: String = row["key"]
            guard let key = NoteKey(rawValue: rawKey) else { return nil }
            return OverlayRecord(
                docID: row["id"], key: key, layer: row["layer"], kind: NoteKind(rawValue: row["kind"]),
                sourcePluginID: PluginID(rawValue: row["source_plugin_id"]), title: row["title_override"],
                startedAtMs: row["source_started_at_ms"],
                createdAt: Date(timeIntervalSince1970: row["created_at"]),
                updatedAt: Date(timeIntervalSince1970: row["updated_at"]), isKept: row["kept"])
        }
    }

    /// Live (not detached) overlays of recorded notes with these keys.
    func liveOverlays(for keys: [NoteKey]) throws -> [OverlayRecord] {
        guard !keys.isEmpty else { return [] }
        return try read { db in
            var result: [OverlayRecord] = []
            for chunk in stride(from: 0, to: keys.count, by: 500) {
                let part = keys[chunk..<min(chunk + 500, keys.count)].map(\.rawValue)
                let marks = databaseQuestionMarks(count: part.count)
                result += try overlayRecords(
                    db,
                    where: "d.key IN (\(marks)) AND d.source_plugin_id != 'notes' AND d.source_state IS NOT 'detached'",
                    arguments: StatementArguments(part))
            }
            return result
        }
    }

    func manualOverlays() throws -> [OverlayRecord] {
        try read { db in try overlayRecords(db, where: "d.source_plugin_id = 'notes'", arguments: []) }
    }

    func detachedOverlays() throws -> [OverlayRecord] {
        try read { db in try overlayRecords(db, where: "d.source_state = 'detached'", arguments: []) }
    }

    /// Live, kept overlays of recorded notes whose plugin is not in `excluding`.
    func keptOverlays(excludingPlugins excluding: Set<PluginID>) throws -> [OverlayRecord] {
        try read { db in
            try overlayRecords(
                db, where: "d.source_plugin_id != 'notes' AND d.source_state IS NOT 'detached' AND \(Self.keptSQL)",
                arguments: []
            ).filter { !excluding.contains($0.sourcePluginID) }
        }
    }

    func liveOverlayKeys() throws -> [NoteKey] {
        try read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT key FROM note_doc
                    WHERE source_plugin_id != 'notes' AND source_state IS NOT 'detached' ORDER BY key
                    """
            ).compactMap { NoteKey(rawValue: $0) }
        }
    }
}

extension NoteKey {
    /// A key read back from the database; `nil` for anything that is not `<plugin id>:<id>`.
    init?(rawValue raw: String) {
        guard let separator = raw.firstIndex(of: ":"), separator != raw.startIndex,
            raw.index(after: separator) != raw.endIndex
        else { return nil }
        self.init(
            pluginID: PluginID(rawValue: String(raw[..<separator])),
            id: String(raw[raw.index(after: separator)...]))
    }
}
