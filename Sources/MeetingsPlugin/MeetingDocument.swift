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

    /// Sets the title of a meeting; a blank title clears it (the library shows the date instead). The title is
    /// not part of the notes text, so the notes stay current.
    func renameMeeting(_ id: Int64, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        try setTitle(id, title: trimmed.isEmpty ? nil : trimmed)
    }

    /// Deletes a meeting (its speakers and segments go with it) and its audio spool folder, if one is left.
    /// A meeting that is still being recorded or processed is refused. Returns false when it does not exist.
    @discardableResult
    func deleteMeeting(_ id: Int64, spool: any SpoolMaintenance) throws -> Bool {
        let found: (uuid: String, status: String)? = try read { db in
            try Row.fetchOne(db, sql: "SELECT uuid, status FROM meeting WHERE id = ?", arguments: [id])
                .map { (uuid: $0["uuid"], status: $0["status"]) }
        }
        guard let found else { return false }
        if MeetingStatus(rawValue: found.status)?.isActive == true { throw MeetingActionError.active }
        try deleteMeetings([id])
        _ = spool.removeSpools(forMeetings: [found.uuid])
        return true
    }
}
