import Foundation
import GRDB
import LintelKit

/// One document Export All writes: metadata only, the head comes from `headRevision(of:)`.
struct ExportRow: Sendable, Equatable {
    var docID: Int64
    var key: NoteKey
    var layer: String
    var kind: NoteKind
    var sourcePluginID: PluginID
    var titleOverride: String?
    var isDetached: Bool
    var createdAt: Date
    var updatedAt: Date
}

/// An open comment with the text it is anchored to. Holds other people's words: never logged.
struct ExportComment: Sendable, Equatable {
    var id: Int64
    var threadID: Int64
    var author: String
    var createdAt: Date
    var body: String
    var quote: String
}

extension NotesStore {
    /// Every document Export All may write, oldest first: a `detached` row without user writing and without an
    /// open comment is leftover (deleted as soon as it is not open) and is skipped.
    func exportRows() throws -> [ExportRow] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT d.id, d.key, d.layer, d.kind, d.source_plugin_id, d.title_override, d.source_state,
                        d.created_at, d.updated_at
                    FROM note_doc d
                    WHERE NOT (d.source_state = 'detached' AND NOT \(Self.keptSQL)) ORDER BY d.id
                    """
            ).compactMap { row -> ExportRow? in
                let raw: String = row["key"]
                guard let key = NoteKey(rawValue: raw) else { return nil }
                let state: String? = row["source_state"]
                return ExportRow(
                    docID: row["id"], key: key, layer: row["layer"], kind: NoteKind(rawValue: row["kind"]),
                    sourcePluginID: PluginID(rawValue: row["source_plugin_id"]), titleOverride: row["title_override"],
                    isDetached: state == NoteSourceState.detached.rawValue,
                    createdAt: Date(timeIntervalSince1970: row["created_at"]),
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
            }
        }
    }

    func openComments(of docID: Int64) throws -> [ExportComment] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, thread_id, author, created_at, body, anchor_quote FROM note_comment
                    WHERE doc_id = ? AND status = 'open' ORDER BY thread_id, id
                    """, arguments: [docID]
            ).map { row in
                ExportComment(
                    id: row["id"], threadID: row["thread_id"], author: row["author"],
                    createdAt: Date(timeIntervalSince1970: row["created_at"]), body: row["body"],
                    quote: row["anchor_quote"])
            }
        }
    }
}
