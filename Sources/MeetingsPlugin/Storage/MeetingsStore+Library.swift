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

    /// The most recent meetings first, optionally filtered, optionally only those whose title, notes or
    /// transcript match `text`.
    ///
    /// The text is folded like the index (`FullTextFolding`) and every typed word is a prefix; one segment of
    /// the transcript (or the notes, or the title) has to contain all of the words. A text without any
    /// searchable word finds nothing. `limit` is the most rows returned.
    func libraryEntries(matching text: String?, filter: MeetingLibraryFilter, limit: Int) throws
        -> [MeetingLibraryEntry]
    {
        var conditions: [String] = []
        var arguments: StatementArguments = ["limit": max(0, limit)]
        if let clause = filter.clause { conditions.append(clause) }
        if let text {
            // A pasted page is not a search: only the first words count.
            let words = FullTextFolding.fold(text).split(whereSeparator: \.isWhitespace).prefix(Self.maxQueryWords)
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: words.joined(separator: " ")) else { return [] }
            arguments += ["pattern": pattern]
            conditions.append(
                """
                (id IN (SELECT segment.meeting_id FROM meeting_fts
                        JOIN meeting_segment AS segment ON segment.id = meeting_fts.rowid
                        WHERE meeting_fts MATCH :pattern)
                 OR id IN (SELECT rowid FROM meeting_notes_fts WHERE meeting_notes_fts MATCH :pattern))
                """)
        }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, started_at, duration_ms, title, source_bundle_id, status, notes_status,
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
                    hasNotes: (row["has_notes"] as Int) != 0)
            }
        }
    }
}
