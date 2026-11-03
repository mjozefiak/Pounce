import Foundation
import GRDB

/// One meeting as crash recovery sees it: no transcript text, only what decides what to do with it.
struct RecoverableMeeting: Equatable, Sendable {
    let id: Int64
    /// `nil` when the stored `uuid` is not a UUID (then there is no spool folder to find).
    let uuid: UUID?
    let status: MeetingStatus
    let audioState: AudioState
    let startedAt: Date
    let endedAt: Date?
    let durationMs: Int
    let segmentCount: Int
}

/// Reads for crash recovery and "Dokończ" (spec step 1.7).
extension MeetingsStore {
    /// The meetings with one of these statuses, oldest first.
    func recoverableMeetings(statuses: [MeetingStatus]) throws -> [RecoverableMeeting] {
        let names = statuses.map(\.rawValue)
        guard !names.isEmpty else { return [] }
        return try read { db in
            let marks = names.map { _ in "?" }.joined(separator: ", ")
            return try Row.fetchAll(
                db,
                sql: """
                    SELECT m.id, m.uuid, m.status, m.audio_state, m.started_at, m.ended_at, m.duration_ms,
                        (SELECT count(*) FROM meeting_segment s WHERE s.meeting_id = m.id) AS segments
                    FROM meeting m WHERE m.status IN (\(marks)) ORDER BY m.started_at, m.id
                    """, arguments: StatementArguments(names)
            ).compactMap(Self.recoverable)
        }
    }

    func recoverableMeeting(id: Int64) throws -> RecoverableMeeting? {
        try read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT m.id, m.uuid, m.status, m.audio_state, m.started_at, m.ended_at, m.duration_ms,
                        (SELECT count(*) FROM meeting_segment s WHERE s.meeting_id = m.id) AS segments
                    FROM meeting m WHERE m.id = ?
                    """, arguments: [id]
            ).flatMap(Self.recoverable)
        }
    }

    private static func recoverable(_ row: Row) -> RecoverableMeeting? {
        let status: String = row["status"]
        let audio: String = row["audio_state"]
        guard let status = MeetingStatus(rawValue: status), let audio = AudioState(rawValue: audio) else { return nil }
        let uuid: String = row["uuid"]
        let ended: Double? = row["ended_at"]
        return RecoverableMeeting(
            id: row["id"], uuid: UUID(uuidString: uuid), status: status, audioState: audio,
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            endedAt: ended.map(Date.init(timeIntervalSince1970:)),
            durationMs: row["duration_ms"], segmentCount: row["segments"])
    }

    /// The end of the last stored segment in milliseconds, 0 without segments.
    func lastSegmentEndMs(meetingID: Int64) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db, sql: "SELECT max(end_ms) FROM meeting_segment WHERE meeting_id = ?", arguments: [meetingID]) ?? 0
        }
    }

    /// The meeting's stored text of one track on the shared timeline, for the echo check. Never logged.
    func trackSegments(meetingID: Int64, channel: AudioChannel) throws -> [TrackSegment] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT start_ms, end_ms, text FROM meeting_segment
                    WHERE meeting_id = ? AND channel = ? ORDER BY start_ms, id
                    """, arguments: [meetingID, channel.rawValue]
            ).map {
                TrackSegment(
                    track: channel == .system ? .system : .microphone, startMs: $0["start_ms"], endMs: $0["end_ms"],
                    text: $0["text"])
            }
        }
    }
}

/// Writes for crash recovery and "Dokończ". Each one is a single transaction.
extension MeetingsStore {
    /// A meeting recovery keeps resuming after crashes: it gives up after this many tries.
    static let maximumResumeAttempts = 3

    /// Counts one more automatic resume of a `processing` meeting and returns the new count.
    func bumpResumeAttempts(_ id: Int64) throws -> Int {
        try write { db in
            try db.execute(
                sql: "UPDATE meeting SET resume_attempts = resume_attempts + 1 WHERE id = ?", arguments: [id])
            return try Int.fetchOne(db, sql: "SELECT resume_attempts FROM meeting WHERE id = ?", arguments: [id]) ?? 0
        }
    }

    /// Atomically takes an `incomplete` meeting for "Dokończ": it becomes `processing` (so retention and
    /// recovery leave it and its spool alone) and its attempt counter starts again. `false` when the meeting is
    /// gone or no longer `incomplete`.
    func claimForFinishing(_ id: Int64) throws -> Bool {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE meeting SET status = 'processing', resume_attempts = 0
                    WHERE id = ? AND status = 'incomplete'
                    """, arguments: [id])
            return db.changesCount == 1
        }
    }

    /// Gives a claimed meeting back (`processing` to `incomplete`); anything else is left alone.
    func releaseFinishing(_ id: Int64) throws {
        try write { db in
            try db.execute(
                sql: "UPDATE meeting SET status = 'incomplete' WHERE id = ? AND status = 'processing'", arguments: [id])
        }
    }

    /// Status, end time, duration and (optionally) `audio_state = deleted` in one write.
    func setRecovered(
        _ id: Int64, status: MeetingStatus, endedAt: Date?, durationMs: Int, audioDeleted: Bool = false,
        gap: Bool? = nil
    ) throws {
        try write { db in
            try db.execute(
                sql: """
                    UPDATE meeting SET status = ?, ended_at = COALESCE(?, ended_at), duration_ms = ?,
                        audio_state = CASE WHEN ? THEN 'deleted' ELSE audio_state END,
                        audio_gap = COALESCE(?, audio_gap)
                    WHERE id = ?
                    """,
                arguments: [status.rawValue, endedAt?.timeIntervalSince1970, durationMs, audioDeleted, gap, id])
        }
    }

    /// `true` when part of the meeting's audio is known to be missing from the transcript (the user chose to
    /// finish anyway, or the audio could not be checked).
    func hasAudioGap(_ id: Int64) throws -> Bool {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT audio_gap FROM meeting WHERE id = ?", arguments: [id]) == 1
        }
    }

    func resumeAttempts(_ id: Int64) throws -> Int {
        try read { db in
            try Int.fetchOne(db, sql: "SELECT resume_attempts FROM meeting WHERE id = ?", arguments: [id]) ?? 0
        }
    }

    /// `ready` meetings whose audio is still marked as spooled: a delete that did not finish.
    func readyMeetingsWithSpool() throws -> [(id: Int64, uuid: UUID)] {
        try read { db in
            try Row.fetchAll(db, sql: "SELECT id, uuid FROM meeting WHERE status = 'ready' AND audio_state = 'spool'")
                .compactMap { row in
                    UUID(uuidString: row["uuid"]).map { (row["id"] as Int64, $0) }
                }
        }
    }
}
