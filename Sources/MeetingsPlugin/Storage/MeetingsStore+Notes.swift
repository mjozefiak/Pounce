import Foundation
import GRDB

/// What the notes of one meeting say about themselves: the columns `notes_*` of `meeting` except the text.
struct NotesRecord: Equatable, Sendable {
    var status: NotesStatus
    var promptVersion: String?
    var model: String?
    var droppedCount: Int
    var generatedAt: Date?
    var hasMarkdown: Bool
}

/// The writes of the notes pipeline (`NotesService`). Every transition is one statement guarded by the status
/// it expects, so a rename, a delete or a second job between two steps cannot be overwritten: a stale writer
/// changes nothing. The transcript is never touched here.
extension MeetingsStore {
    /// `ready` → notes `running`. Returns the status the notes had before (to put back when the run is
    /// cancelled), or `nil` when the meeting is gone, is not `ready`, or its notes already run.
    func beginNotes(_ id: Int64) throws -> NotesStatus? {
        try write { db in
            guard
                let raw = try String.fetchOne(
                    db, sql: "SELECT notes_status FROM meeting WHERE id = ? AND status = 'ready'", arguments: [id]),
                let previous = NotesStatus(rawValue: raw), previous != .running
            else { return nil }
            try db.execute(
                sql: "UPDATE meeting SET notes_status = 'running' WHERE id = ? AND notes_status = ?",
                arguments: [id, raw])
            return db.changesCount == 1 ? previous : nil
        }
    }

    /// What `finishNotes` did.
    enum NotesFinish: Equatable, Sendable {
        /// The text and the status were written.
        case stored
        /// The text was written but the status stays `stale`: a speaker was renamed (or "To ja" moved) while the
        /// notes were being written, so they use the old names.
        case storedStale
        /// Nothing was written: the meeting is gone or its notes were not being written.
        case discarded
    }

    /// The finished notes, `running` → `ok` / `partial`, or → `stale` when a rename marked them `stale` while they
    /// were written (the text is kept all the same). A `nil` text keeps the earlier one.
    @discardableResult
    func finishNotes(
        _ id: Int64, markdown: String?, status: NotesStatus, promptVersion: String, model: String,
        droppedCount: Int, generatedAt: Date
    ) throws -> NotesFinish {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE meeting SET notes_markdown = COALESCE(?, notes_markdown),
                        notes_status = CASE WHEN notes_status = 'stale' THEN 'stale' ELSE ? END,
                        notes_prompt_version = ?, notes_model = ?, notes_dropped_count = ?, notes_generated_at = ?
                    WHERE id = ? AND notes_status IN ('running', 'stale')
                    """,
                arguments: [
                    markdown, status.rawValue, promptVersion, model, max(0, droppedCount),
                    generatedAt.timeIntervalSince1970, id,
                ])
            guard db.changesCount == 1 else { return .discarded }
            let now = try String.fetchOne(db, sql: "SELECT notes_status FROM meeting WHERE id = ?", arguments: [id])
            return now == NotesStatus.stale.rawValue ? .storedStale : .stored
        }
    }

    /// `running` → `status` without touching the text: a failed run (`failed`) or a cancelled one (the status
    /// from before). Returns false when the notes were not `running`.
    @discardableResult
    func settleNotes(_ id: Int64, status: NotesStatus) throws -> Bool {
        try write { db in
            try db.execute(
                sql: "UPDATE meeting SET notes_status = ? WHERE id = ? AND notes_status = 'running'",
                arguments: [status.rawValue, id])
            return db.changesCount == 1
        }
    }

    /// Crash recovery: notes left `running` by a process that died become `failed` (the text, if any, stays).
    /// Returns how many meetings that was. `excluding` are meetings a job of this process works on.
    @discardableResult
    func failInterruptedNotes(excluding: Set<Int64> = []) throws -> Int {
        try write { db in
            let ids = try Int64.fetchAll(db, sql: "SELECT id FROM meeting WHERE notes_status = 'running'")
            var changed = 0
            for id in ids where !excluding.contains(id) {
                try db.execute(
                    sql: "UPDATE meeting SET notes_status = 'failed' WHERE id = ? AND notes_status = 'running'",
                    arguments: [id])
                changed += db.changesCount
            }
            return changed
        }
    }

    func notesRecord(of id: Int64) throws -> NotesRecord? {
        try read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT notes_status, notes_prompt_version, notes_model, notes_dropped_count,
                            notes_generated_at, (notes_markdown IS NOT NULL) AS has_markdown
                        FROM meeting WHERE id = ?
                        """, arguments: [id])
            else { return nil }
            return NotesRecord(
                status: NotesStatus(rawValue: row["notes_status"]) ?? .none, promptVersion: row["notes_prompt_version"],
                model: row["notes_model"], droppedCount: row["notes_dropped_count"],
                generatedAt: (row["notes_generated_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                hasMarkdown: (row["has_markdown"] as Int) != 0)
        }
    }
}
