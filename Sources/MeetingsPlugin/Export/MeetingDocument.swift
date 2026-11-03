import Foundation
import GRDB

/// A read-only snapshot of one meeting: what the meeting window shows and `MarkdownExporter` writes.
struct MeetingDocument: Sendable, Equatable {
    struct Speaker: Sendable, Equatable, Identifiable {
        var id: Int64
        var label: String
        var isSelf: Bool
        var channel: AudioChannel
    }

    struct Segment: Sendable, Equatable, Identifiable {
        var id: Int64
        var channel: AudioChannel
        var startMs: Int
        var endMs: Int
        var speakerID: Int64?
        var text: String
    }

    var id: Int64
    var uuid: String
    var startedAt: Date
    var durationMs: Int
    var title: String?
    var status: MeetingStatus
    var speakerMode: SpeakerMode
    var audioState: AudioState
    var notesMarkdown: String?
    var notesStatus: NotesStatus
    var notesDroppedCount: Int
    var speakers: [Speaker]
    var segments: [Segment]

    func speaker(id: Int64?) -> Speaker? {
        guard let id else { return nil }
        return speakers.first { $0.id == id }
    }
}

enum MeetingActionError: Error, Equatable {
    /// The meeting is being recorded or processed; deleting it would pull the data from under the session.
    case active
    /// The audio spool folder could not be removed; the meeting was left as it was.
    case spoolNotRemoved
}

extension MeetingsStore {
    /// The whole meeting for the window and the export; `nil` when it does not exist.
    func loadDocument(id: Int64) throws -> MeetingDocument? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM meeting WHERE id = ?", arguments: [id]) else {
                return nil
            }
            let speakers = try Row.fetchAll(
                db, sql: "SELECT * FROM meeting_speaker WHERE meeting_id = ? ORDER BY id", arguments: [id]
            ).map { row in
                MeetingDocument.Speaker(
                    id: row["id"], label: row["label"], isSelf: (row["is_self"] as Int) != 0,
                    channel: AudioChannel(rawValue: row["source_channel"]) ?? .mic)
            }
            let segments = try Row.fetchAll(
                db, sql: "SELECT * FROM meeting_segment WHERE meeting_id = ? ORDER BY start_ms, id", arguments: [id]
            ).map { row in
                MeetingDocument.Segment(
                    id: row["id"], channel: AudioChannel(rawValue: row["channel"]) ?? .mic,
                    startMs: row["start_ms"], endMs: row["end_ms"], speakerID: row["speaker_id"],
                    text: row["text"])
            }
            return MeetingDocument(
                id: id, uuid: row["uuid"], startedAt: Date(timeIntervalSince1970: row["started_at"]),
                durationMs: row["duration_ms"], title: row["title"],
                status: MeetingStatus(rawValue: row["status"]) ?? .failed,
                speakerMode: SpeakerMode(rawValue: row["speaker_mode"]) ?? .none,
                audioState: AudioState(rawValue: row["audio_state"]) ?? .deleted,
                notesMarkdown: row["notes_markdown"],
                notesStatus: NotesStatus(rawValue: row["notes_status"]) ?? .none,
                notesDroppedCount: row["notes_dropped_count"], speakers: speakers, segments: segments)
        }
    }

    /// Sets the title of a meeting; a blank title (also one of invisible characters only) clears it (the
    /// library shows the date instead). The title is not part of the notes text, so the notes stay current.
    func renameMeeting(_ id: Int64, title: String) throws {
        let cleaned = MarkdownExporter.cleaned(title, keepNewlines: false)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try setTitle(id, title: cleaned.isEmpty ? nil : cleaned)
    }

    /// Deletes a meeting (its speakers and segments go with it) and its audio spool folder, if one is left.
    ///
    /// One write transaction: the row is deleted only while the meeting is not `recording` or `processing`
    /// (so a "Dokończ" that claimed it a moment ago wins and nothing is lost), the spool folder is removed
    /// next and the transaction commits only when the folder is really gone. If it cannot be removed the
    /// whole delete is rolled back (`spoolNotRemoved`): the meeting stays, with its audio, and the user can
    /// try again. A spool folder without a row (a crash in between) is swept by `OrphanSpoolSweep`.
    /// Returns false when the meeting does not exist.
    @discardableResult
    func deleteMeeting(_ id: Int64, spool: any SpoolMaintenance) throws -> Bool {
        try write { db in
            guard
                let uuid = try String.fetchOne(
                    db, sql: "SELECT uuid FROM meeting WHERE id = ?", arguments: [id])
            else { return false }
            try db.execute(
                sql: "DELETE FROM meeting WHERE id = ? AND status NOT IN ('recording', 'processing')",
                arguments: [id])
            guard db.changesCount == 1 else { throw MeetingActionError.active }
            _ = spool.removeSpools(forMeetings: [uuid])
            if spool.hasSpool(forMeeting: uuid) { throw MeetingActionError.spoolNotRemoved }
            return true
        }
    }

    /// The `uuid` of every meeting row (what `OrphanSpoolSweep` compares the spool folders with).
    func allMeetingUUIDs() throws -> Set<String> {
        try read { db in Set(try String.fetchAll(db, sql: "SELECT uuid FROM meeting")) }
    }
}
