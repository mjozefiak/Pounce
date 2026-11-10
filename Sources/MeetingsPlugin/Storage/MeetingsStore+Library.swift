import Foundation
import GRDB

/// One row of the meeting library list: what the list shows, without the transcript or the notes.
struct MeetingLibraryEntry: Sendable, Equatable {
    var id: Int64
    var startedAt: Date
    var durationMs: Int
    var title: String?
    var sourceBundleID: String?
    var status: MeetingStatus
    var notesStatus: NotesStatus
    /// Whether `notes_markdown` holds text (the notes may be `stale` or `partial` and still be there).
    var hasNotes: Bool
    /// The stable public id of the meeting (`meetings:<uuid>` in the Notes workspace); empty only in fixtures.
    var uuid: String = ""
    /// Whether the audio spool is still there (an `incomplete` meeting can then be finished).
    var audioSpooled: Bool = false
}

/// The list mode's filters (⌘1 to ⌘3).
enum MeetingLibraryFilter: String, Sendable, CaseIterable {
    case all
    case withNotes
    case needsAttention

    /// The SQL condition on the `meeting` table, or `nil` for everything.
    var clause: String? {
        switch self {
        case .all: nil
        case .withNotes: "(notes_markdown IS NOT NULL AND notes_markdown <> '')"
        // Interrupted or failed meetings, and notes that failed or no longer match the speakers' names.
        case .needsAttention: "(status IN ('incomplete', 'failed') OR notes_status IN ('failed', 'stale'))"
        }
    }
}

extension MeetingsStore {
    /// The most words of a library query that take part in the search.
    static let maxQueryWords = 20

    /// Where a page of `libraryEntries` starts: after the row with this start time and id (newest first).
    struct LibraryPosition: Sendable, Equatable {
        var startedAt: Double
        var id: Int64
    }

    /// The WHERE clause and arguments of a library query, or `nil` when the text has no searchable word (it
    /// finds nothing).
    private func libraryConditions(
        matching text: String?, filter: MeetingLibraryFilter, after: LibraryPosition?
    ) -> (clause: String, arguments: StatementArguments)? {
        var conditions: [String] = []
        var arguments = StatementArguments()
        if let clause = filter.clause { conditions.append(clause) }
        if let after {
            conditions.append("(started_at < :afterStart OR (started_at = :afterStart AND id < :afterID))")
            arguments += ["afterStart": after.startedAt, "afterID": after.id]
        }
        if let text {
            // A pasted page is not a search: only the first words count.
            let words = FullTextFolding.fold(text).split(whereSeparator: \.isWhitespace).prefix(Self.maxQueryWords)
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: words.joined(separator: " ")) else { return nil }
            arguments += ["pattern": pattern]
            conditions.append(
                """
                (id IN (SELECT segment.meeting_id FROM meeting_fts
                        JOIN meeting_segment AS segment ON segment.id = meeting_fts.rowid
                        WHERE meeting_fts MATCH :pattern)
                 OR id IN (SELECT rowid FROM meeting_notes_fts WHERE meeting_notes_fts MATCH :pattern))
                """)
        }
        return (conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND "), arguments)
    }

    /// The most recent meetings first, optionally filtered, optionally only those whose title, notes or
    /// transcript match `text`, optionally only those after `after` (paging).
    ///
    /// The text is folded like the index (`FullTextFolding`) and every typed word is a prefix; one segment of
    /// the transcript (or the notes, or the title) has to contain all of the words. A text without any
    /// searchable word finds nothing. `limit` is the most rows returned.
    func libraryEntries(
        matching text: String?, filter: MeetingLibraryFilter, limit: Int, after: LibraryPosition? = nil
    ) throws -> [MeetingLibraryEntry] {
        guard let (whereClause, conditionArguments) = libraryConditions(matching: text, filter: filter, after: after)
        else { return [] }
        var arguments: StatementArguments = ["limit": max(0, limit)]
        arguments += conditionArguments
        return try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, uuid, started_at, duration_ms, title, source_bundle_id, status, notes_status,
                           (audio_state = 'spool') AS audio_spooled,
                           (notes_markdown IS NOT NULL AND notes_markdown <> '') AS has_notes
                    FROM meeting \(whereClause)
                    ORDER BY started_at DESC, id DESC LIMIT :limit
                    """,
                arguments: arguments
            ).map { row in
                MeetingLibraryEntry(
                    id: row["id"], startedAt: Date(timeIntervalSince1970: row["started_at"]),
                    durationMs: row["duration_ms"], title: row["title"], sourceBundleID: row["source_bundle_id"],
                    status: MeetingStatus(rawValue: row["status"]) ?? .failed,
                    notesStatus: NotesStatus(rawValue: row["notes_status"]) ?? .none,
                    hasNotes: (row["has_notes"] as Int) != 0, uuid: row["uuid"],
                    audioSpooled: (row["audio_spooled"] as Int) != 0)
            }
        }
    }

    /// How many meetings the same query finds in all (what a pager shows as the total).
    func libraryCount(matching text: String?, filter: MeetingLibraryFilter) throws -> Int {
        guard let (whereClause, arguments) = libraryConditions(matching: text, filter: filter, after: nil) else {
            return 0
        }
        return try read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meeting \(whereClause)", arguments: arguments) ?? 0
        }
    }

    /// One library row by `uuid`; `nil` when there is no such meeting.
    func libraryEntry(uuid: String) throws -> MeetingLibraryEntry? {
        try libraryEntries(uuids: [uuid]).first
    }

    /// The rows of these meetings, newest first (what `exists` and the actions need).
    func libraryEntries(uuids: [String]) throws -> [MeetingLibraryEntry] {
        guard !uuids.isEmpty else { return [] }
        let placeholders = uuids.map { _ in "?" }.joined(separator: ", ")
        return try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, uuid, started_at, duration_ms, title, source_bundle_id, status, notes_status,
                           (audio_state = 'spool') AS audio_spooled,
                           (notes_markdown IS NOT NULL AND notes_markdown <> '') AS has_notes
                    FROM meeting WHERE uuid IN (\(placeholders)) ORDER BY started_at DESC, id DESC
                    """,
                arguments: StatementArguments(uuids)
            ).map { row in
                MeetingLibraryEntry(
                    id: row["id"], startedAt: Date(timeIntervalSince1970: row["started_at"]),
                    durationMs: row["duration_ms"], title: row["title"], sourceBundleID: row["source_bundle_id"],
                    status: MeetingStatus(rawValue: row["status"]) ?? .failed,
                    notesStatus: NotesStatus(rawValue: row["notes_status"]) ?? .none,
                    hasNotes: (row["has_notes"] as Int) != 0, uuid: row["uuid"],
                    audioSpooled: (row["audio_spooled"] as Int) != 0)
            }
        }
    }

    /// The `uuid` of the meeting with this row id.
    func meetingUUID(id: Int64) throws -> String? {
        try read { db in try String.fetchOne(db, sql: "SELECT uuid FROM meeting WHERE id = ?", arguments: [id]) }
    }

    /// The row id of the meeting with this `uuid`.
    func meetingID(uuid: String) throws -> Int64? {
        try read { db in try Int64.fetchOne(db, sql: "SELECT id FROM meeting WHERE uuid = ?", arguments: [uuid]) }
    }
}
