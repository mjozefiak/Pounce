import Foundation
import GRDB
import PouncePersistence
import Synchronization

enum MeetingsStoreError: Error {
    /// The store was closed (the plugin deactivated) while background work still used it.
    case closed
}

/// `meeting.status` (spec: Data Model).
enum MeetingStatus: String, Sendable, CaseIterable {
    case recording
    case processing
    case ready
    case incomplete
    case failed

    /// A meeting that is being recorded or finished; retention never deletes these.
    var isActive: Bool { self == .recording || self == .processing }
}

/// `meeting.notes_status`.
enum NotesStatus: String, Sendable, CaseIterable {
    case none
    case running
    case ok
    case partial
    case failed
    case stale
}

/// `meeting.speaker_mode`.
enum SpeakerMode: String, Sendable, CaseIterable {
    case diarized
    case channels
    case none
}

/// `meeting.audio_state`.
enum AudioState: String, Sendable, CaseIterable {
    case spool
    case deleted
}

/// `meeting_speaker.source_channel` and `meeting_segment.channel`.
enum AudioChannel: String, Sendable, CaseIterable {
    case mic
    case system
}

/// The encrypted meetings library: `meetings.sqlite` (SQLCipher) in `Plugins/meetings/`, with two FTS5
/// indexes (the transcript and the title plus notes) kept in sync by triggers (spec: Data Model). GRDB
/// serialises access, so the store is safe to use from any task. Transcript text and notes never reach a log.
final class MeetingsStore: Sendable {
    static let fileName = "meetings.sqlite"

    private let database: DatabaseQueue
    private let lock = NSLock()
    private let closed = Mutex(false)

    init(database: DatabaseQueue) {
        self.database = database
    }

    var isClosed: Bool { closed.withLock { $0 } }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try access { try $0.read(value) }
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try access { try $0.write(updates) }
    }

    func vacuum() throws {
        try access { try $0.vacuum() }
    }

    /// Closes the database. Waits for an access in progress; any later access throws
    /// `MeetingsStoreError.closed`.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        closed.withLock { $0 = true }
        try database.close()
    }

    private func access<T>(_ body: (DatabaseQueue) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw MeetingsStoreError.closed }
        return try body(database)
    }

    /// Opens (or creates) the encrypted database in `directory` (mode 0700; the file is 0600).
    static func open(in directory: URL, keys: MeetingKeys, fileManager: FileManager = .default) throws
        -> MeetingsStore
    {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let queue = try DatabaseFactory.openQueue(
            at: directory.appending(path: fileName), key: keys.database, migrator: migrator, fileManager: fileManager)
        // Deleted rows are overwritten instead of lingering in free pages.
        do {
            try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        } catch {
            try? queue.close()
            throw error
        }
        return MeetingsStore(database: queue)
    }

    /// The frozen folding expression of migration `v1-meetings`: nested `replace()` calls for ł, Ł, đ, Đ, ø, Ø
    /// (NULL stays NULL). Never edit; a new folding needs a new migration.
    static func frozenFoldingSQL(_ expression: String) -> String {
        "replace(replace(replace(replace(replace(replace(\(expression), 'ł', 'l'), 'Ł', 'L'), 'đ', 'd'), 'Đ', 'D'), 'ø', 'o'), 'Ø', 'O')"
    }

    /// `meetings.sqlite`'s own migrator. Additive only, never edited once released
    /// (`BACKWARD_COMPATIBILITY.md` section 2).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-meetings") { db in
            try db.execute(
                sql: """
                    CREATE TABLE meeting (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        uuid TEXT NOT NULL UNIQUE,
                        started_at DOUBLE NOT NULL,
                        ended_at DOUBLE,
                        duration_ms INTEGER NOT NULL DEFAULT 0,
                        title TEXT,
                        source_bundle_id TEXT,
                        status TEXT NOT NULL DEFAULT 'recording',
                        speaker_mode TEXT NOT NULL DEFAULT 'none',
                        languages TEXT NOT NULL DEFAULT '',
                        speech_model_id TEXT NOT NULL DEFAULT '',
                        diarization_model_id TEXT,
                        audio_state TEXT NOT NULL DEFAULT 'spool',
                        notes_markdown TEXT,
                        notes_status TEXT NOT NULL DEFAULT 'none',
                        notes_prompt_version TEXT,
                        notes_model TEXT,
                        notes_dropped_count INTEGER NOT NULL DEFAULT 0,
                        notes_generated_at DOUBLE,
                        resume_attempts INTEGER NOT NULL DEFAULT 0,
                        audio_gap INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE INDEX meeting_on_started_at ON meeting(started_at);
                    CREATE TABLE meeting_speaker (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        meeting_id INTEGER NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                        label TEXT NOT NULL,
                        is_self INTEGER NOT NULL DEFAULT 0,
                        source_channel TEXT NOT NULL
                    );
                    CREATE INDEX meeting_speaker_on_meeting_id ON meeting_speaker(meeting_id);
                    CREATE TABLE meeting_segment (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        meeting_id INTEGER NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                        channel TEXT NOT NULL,
                        start_ms INTEGER NOT NULL,
                        end_ms INTEGER NOT NULL,
                        speaker_id INTEGER REFERENCES meeting_speaker(id) ON DELETE SET NULL,
                        text TEXT NOT NULL
                    );
                    CREATE INDEX meeting_segment_on_meeting_id ON meeting_segment(meeting_id, start_ms);
                    CREATE INDEX meeting_segment_on_speaker_id ON meeting_segment(speaker_id);
                    """
            )
            // "zolc" finds "żółć": `remove_diacritics 2` folds ż, ó and ć but not ł, which has no decomposition.
            // The index therefore reads the text through a view that folds the few letters SQLite leaves alone;
            // the triggers fold the same way, and queries are folded in Swift (`FullTextFolding`).
            // The folding below is FROZEN: this migration never changes after release, so the letters are
            // written out here instead of being read from `FullTextFolding.pairs`. A test compares both; adding
            // a letter to `pairs` later fails it and needs a NEW migration that rebuilds the views, triggers
            // and indexes.
            let segmentText = frozenFoldingSQL("text")
            let newSegmentText = frozenFoldingSQL("new.text")
            let oldSegmentText = frozenFoldingSQL("old.text")
            let notes = frozenFoldingSQL("notes_markdown")
            let newTitle = frozenFoldingSQL("new.title")
            let oldTitle = frozenFoldingSQL("old.title")
            let newNotes = frozenFoldingSQL("new.notes_markdown")
            let oldNotes = frozenFoldingSQL("old.notes_markdown")
            try db.execute(
                sql: """
                    CREATE VIEW meeting_segment_indexed AS SELECT id, \(segmentText) AS text FROM meeting_segment;
                    CREATE VIRTUAL TABLE meeting_fts USING fts5(
                        text, content='meeting_segment_indexed', content_rowid='id',
                        tokenize='unicode61 remove_diacritics 2');
                    CREATE TRIGGER meeting_segment_ai AFTER INSERT ON meeting_segment BEGIN
                        INSERT INTO meeting_fts(rowid, text) VALUES (new.id, \(newSegmentText));
                    END;
                    CREATE TRIGGER meeting_segment_ad AFTER DELETE ON meeting_segment BEGIN
                        INSERT INTO meeting_fts(meeting_fts, rowid, text) VALUES ('delete', old.id, \(oldSegmentText));
                    END;
                    CREATE TRIGGER meeting_segment_au AFTER UPDATE OF text ON meeting_segment BEGIN
                        INSERT INTO meeting_fts(meeting_fts, rowid, text) VALUES ('delete', old.id, \(oldSegmentText));
                        INSERT INTO meeting_fts(rowid, text) VALUES (new.id, \(newSegmentText));
                    END;
                    CREATE VIEW meeting_notes_indexed AS
                        SELECT id, \(frozenFoldingSQL("title")) AS title, \(notes) AS notes_markdown FROM meeting;
                    CREATE VIRTUAL TABLE meeting_notes_fts USING fts5(
                        title, notes_markdown, content='meeting_notes_indexed', content_rowid='id',
                        tokenize='unicode61 remove_diacritics 2');
                    CREATE TRIGGER meeting_notes_ai AFTER INSERT ON meeting BEGIN
                        INSERT INTO meeting_notes_fts(rowid, title, notes_markdown)
                        VALUES (new.id, \(newTitle), \(newNotes));
                    END;
                    CREATE TRIGGER meeting_notes_ad AFTER DELETE ON meeting BEGIN
                        INSERT INTO meeting_notes_fts(meeting_notes_fts, rowid, title, notes_markdown)
                        VALUES ('delete', old.id, \(oldTitle), \(oldNotes));
                    END;
                    CREATE TRIGGER meeting_notes_au AFTER UPDATE OF title, notes_markdown ON meeting BEGIN
                        INSERT INTO meeting_notes_fts(meeting_notes_fts, rowid, title, notes_markdown)
                        VALUES ('delete', old.id, \(oldTitle), \(oldNotes));
                        INSERT INTO meeting_notes_fts(rowid, title, notes_markdown)
                        VALUES (new.id, \(newTitle), \(newNotes));
                    END;
                    """
            )
        }
        return migrator
    }
}

// MARK: - Access

extension MeetingsStore {
    // MARK: Writing

    /// Creates the `recording` entry of a new meeting. `uuid` names its spool folder.
    @discardableResult
    func insertMeeting(
        uuid: String, startedAt: Date, speechModelID: String, status: MeetingStatus = .recording,
        sourceBundleID: String? = nil
    ) throws -> Int64 {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting (uuid, started_at, speech_model_id, status, source_bundle_id)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [uuid, startedAt.timeIntervalSince1970, speechModelID, status.rawValue, sourceBundleID])
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    func insertSpeaker(meetingID: Int64, label: String, isSelf: Bool, channel: AudioChannel) throws -> Int64 {
        try write { db in
            try db.execute(
                sql: "INSERT INTO meeting_speaker (meeting_id, label, is_self, source_channel) VALUES (?, ?, ?, ?)",
                arguments: [meetingID, label, isSelf, channel.rawValue])
            return db.lastInsertedRowID
        }
    }

    @discardableResult
    func insertSegment(
        meetingID: Int64, channel: AudioChannel, startMs: Int, endMs: Int, text: String, speakerID: Int64? = nil
    ) throws -> Int64 {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO meeting_segment (meeting_id, channel, start_ms, end_ms, speaker_id, text)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [meetingID, channel.rawValue, startMs, endMs, speakerID, text])
            return db.lastInsertedRowID
        }
    }

    func setSegmentText(_ id: Int64, text: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE meeting_segment SET text = ? WHERE id = ?", arguments: [text, id])
        }
    }

    func setTitle(_ id: Int64, title: String?) throws {
        try write { db in
            try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    func setStatus(_ id: Int64, status: MeetingStatus, endedAt: Date? = nil, durationMs: Int? = nil) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE meeting SET status = ?, ended_at = COALESCE(?, ended_at),
                        duration_ms = COALESCE(?, duration_ms)
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, endedAt?.timeIntervalSince1970, durationMs, id])
        }
    }

    func setNotes(_ id: Int64, markdown: String?, status: NotesStatus) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE meeting SET notes_markdown = ?, notes_status = ? WHERE id = ?",
                arguments: [markdown, status.rawValue, id])
        }
    }

    func setAudioState(_ id: Int64, state: AudioState) throws {
        try write { db in
            try db.execute(sql: "UPDATE meeting SET audio_state = ? WHERE id = ?", arguments: [state.rawValue, id])
        }
    }

    /// Renames a speaker. The notes of the meeting become `stale` when there are notes or they are being written
    /// for the first time (`running`, no text yet); the job then stores its text as `stale`.
    func renameSpeaker(_ id: Int64, label: String) throws {
        try write { db in
            try db.execute(sql: "UPDATE meeting_speaker SET label = ? WHERE id = ?", arguments: [label, id])
            try db.execute(
                sql: """
                    UPDATE meeting SET notes_status = 'stale'
                    WHERE (notes_markdown IS NOT NULL OR notes_status = 'running')
                        AND id = (SELECT meeting_id FROM meeting_speaker WHERE id = ?)
                    """,
                arguments: [id])
        }
    }

    /// Deletes meetings; their speakers and segments go with them (`ON DELETE CASCADE`).
    func deleteMeetings(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
            }
        }
    }

    func deleteAll() throws {
        try write { db in try db.execute(sql: "DELETE FROM meeting") }
    }

    /// Deletes the meetings that started before `cutoff`, except those still being recorded or processed and
    /// those in `excluding` (being finished right now). Returns the `uuid`s of the deleted meetings (their
    /// spool folders).
    @discardableResult
    func applyRetention(cutoff: Date, excluding: Set<Int64> = []) throws -> [String] {
        try write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, uuid FROM meeting WHERE started_at < ? AND status NOT IN ('recording', 'processing')",
                arguments: [cutoff.timeIntervalSince1970]
            ).filter { !excluding.contains($0["id"] as Int64) }
            for row in rows {
                try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [row["id"] as Int64])
            }
            return rows.map { $0["uuid"] as String }
        }
    }

    /// Marks the audio of these meetings as removed (their spool folders were deleted).
    func markAudioDeleted(uuids: [String]) throws {
        guard !uuids.isEmpty else { return }
        try write { db in
            for uuid in uuids {
                try db.execute(sql: "UPDATE meeting SET audio_state = 'deleted' WHERE uuid = ?", arguments: [uuid])
            }
        }
    }

    // MARK: Reading

    /// The `uuid`s of interrupted (`incomplete` or `failed`) meetings whose audio is still in the spool: the only
    /// spools that may age out.
    /// Meetings in `excluding` (being finished right now) are left out.
    func incompleteSpoolUUIDs(excluding: Set<Int64> = []) throws -> [String] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, uuid FROM meeting WHERE status IN ('incomplete', 'failed') AND audio_state = 'spool'"
            ).filter { !excluding.contains($0["id"] as Int64) }.map { $0["uuid"] as String }
        }
    }

    /// How many meetings a retention pass with `cutoff` would delete (the confirmation shows it).
    func expiredMeetingCount(cutoff: Date, excluding protected: Set<Int64> = []) throws -> Int {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id FROM meeting WHERE started_at < ? AND status NOT IN ('recording', 'processing')",
                arguments: [cutoff.timeIntervalSince1970]
            ).filter { !protected.contains($0["id"] as Int64) }.count
        }
    }

    func audioState(of id: Int64) throws -> AudioState? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT audio_state FROM meeting WHERE id = ?", arguments: [id])
                .flatMap(AudioState.init(rawValue:))
        }
    }

    func meetingCount() throws -> Int {
        try read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting") ?? 0 }
    }

    func segmentCount(meetingID: Int64? = nil) throws -> Int {
        try read { db in
            if let meetingID {
                return try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM meeting_segment WHERE meeting_id = ?", arguments: [meetingID]) ?? 0
            }
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM meeting_segment") ?? 0
        }
    }

    func speakerCount(meetingID: Int64) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db, sql: "SELECT count(*) FROM meeting_speaker WHERE meeting_id = ?", arguments: [meetingID]) ?? 0
        }
    }

    /// Ids of meetings, newest first.
    func meetingIDs() throws -> [Int64] {
        try read { db in try Int64.fetchAll(db, sql: "SELECT id FROM meeting ORDER BY started_at DESC, id DESC") }
    }

    func status(of id: Int64) throws -> MeetingStatus? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT status FROM meeting WHERE id = ?", arguments: [id])
                .flatMap(MeetingStatus.init(rawValue:))
        }
    }

    func notesStatus(of id: Int64) throws -> NotesStatus? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT notes_status FROM meeting WHERE id = ?", arguments: [id])
                .flatMap(NotesStatus.init(rawValue:))
        }
    }

    /// Ids of the segments that match: every typed word as a prefix, best rank first.
    func searchSegments(_ text: String, limit: Int) throws -> [Int64] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: FullTextFolding.fold(text)) else { return [] }
        return try read { db in
            try Int64.fetchAll(
                db, sql: "SELECT rowid FROM meeting_fts WHERE meeting_fts MATCH ? ORDER BY rank LIMIT ?",
                arguments: [pattern, max(0, limit)])
        }
    }

    /// Ids of the meetings whose title or notes match: every typed word as a prefix, best rank first.
    func searchNotes(_ text: String, limit: Int) throws -> [Int64] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: FullTextFolding.fold(text)) else { return [] }
        return try read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT rowid FROM meeting_notes_fts WHERE meeting_notes_fts MATCH ? ORDER BY rank LIMIT ?",
                arguments: [pattern, max(0, limit)])
        }
    }
}

/// The letters `unicode61 remove_diacritics 2` leaves alone because they do not decompose: they are replaced
/// by their plain letter before indexing (in SQL, by the frozen view and triggers of `v1-meetings`) and before searching (in Swift).
/// Everything else (ż, ó, ć, ę, ą, ś, ź, ń, accents) the tokenizer folds itself. The migration's SQL is a frozen
/// copy of `pairs`; changing `pairs` needs a new migration.
enum FullTextFolding {
    static let pairs: [(from: String, to: String)] = [
        ("ł", "l"), ("Ł", "L"), ("đ", "d"), ("Đ", "D"), ("ø", "o"), ("Ø", "O"),
    ]

    static func fold(_ text: String) -> String {
        pairs.reduce(text) { $0.replacingOccurrences(of: $1.from, with: $1.to) }
    }
}
