import Foundation
import GRDB
import LintelKit

/// What deleting a note, or the kept copies of an owner, does to `notes.sqlite` (spec "Delete", L1-39). Every call
/// here is made AFTER the source's own deletion succeeded; none of them runs on its own.
extension NotesStore {
    /// Copies of `owner`'s recordings that Notes keeps (user writing or an open comment): one per recording, however
    /// many of its layers were edited. This is the "N copies in Notes are kept" of Clear, Erase and Delete.
    func keptCopyCount(owner: PluginID) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM (SELECT DISTINCT d.key, IFNULL(d.source_started_at_ms, 0) FROM note_doc d
                        WHERE d.source_plugin_id = ? AND \(Self.keptSQL))
                    """, arguments: [owner.rawValue]) ?? 0
        }
    }

    /// The rows of `owner`'s overlays: the detached ones (their recording is gone), or all of them (Erase Data:
    /// the owner's store is gone, so every copy of its recordings is a copy of nothing).
    func overlayIDs(ofOwner owner: PluginID, detachedOnly: Bool) throws -> [Int64] {
        try read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT id FROM note_doc WHERE source_plugin_id = ?
                    \(detachedOnly ? "AND source_state = 'detached'" : "") ORDER BY id
                    """, arguments: [owner.rawValue])
        }
    }

    /// Deletes these rows (their revisions and comments go with them, ON DELETE CASCADE). Returns how many.
    @discardableResult
    func deleteDocuments(_ ids: [Int64]) throws -> Int {
        try writeMaintenance { db in
            for id in ids { try db.execute(sql: "DELETE FROM note_doc WHERE id = ?", arguments: [id]) }
            return ids.count
        }
    }

    /// The detached overlays of one original recording (the "Recording removed" row), after the user confirmed it.
    @discardableResult
    func deleteDetachedOverlays(key: NoteKey, startedAtMs: Int64) throws -> Int {
        try writeMaintenance { db in
            try db.execute(
                sql: "DELETE FROM note_doc WHERE key = ? AND source_state = 'detached' AND source_started_at_ms IS ?",
                arguments: [key.rawValue, startedAtMs])
            return db.changesCount
        }
    }
}
