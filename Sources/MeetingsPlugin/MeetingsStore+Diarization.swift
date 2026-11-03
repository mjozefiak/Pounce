import Foundation
import GRDB

/// Speaker rows and the segment-to-speaker link (diarization, spec step 1.6).
extension MeetingsStore {
    struct SpeakerRow: Equatable, Sendable {
        let id: Int64
        let label: String
        let isSelf: Bool
        let channel: AudioChannel
    }

    /// The meeting's segments in time order, without their text.
    func segmentRefs(meetingID: Int64) throws -> [SegmentRef] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, channel, start_ms, end_ms FROM meeting_segment
                    WHERE meeting_id = ? ORDER BY start_ms, id
                    """, arguments: [meetingID]
            ).compactMap { row -> SegmentRef? in
                let name: String = row["channel"]
                guard let channel = AudioChannel(rawValue: name) else { return nil }
                return SegmentRef(id: row["id"], channel: channel, startMs: row["start_ms"], endMs: row["end_ms"])
            }
        }
    }

    /// Replaces the meeting's speakers with the plan's in one transaction and sets `speaker_id` of its
    /// segments, `speaker_mode` and `diarization_model_id`. Running it again (a second finalization) starts
    /// from a clean slate: the old speakers go and their segments are re-linked.
    func applySpeakerPlan(_ plan: SpeakerPlan, meetingID: Int64, diarizationModelID: String?) throws {
        try write { db in
            try db.execute(sql: "DELETE FROM meeting_speaker WHERE meeting_id = ?", arguments: [meetingID])
            try db.execute(
                sql: "UPDATE meeting_segment SET speaker_id = NULL WHERE meeting_id = ?", arguments: [meetingID])
            var ids: [Int64] = []
            for speaker in plan.speakers {
                try db.execute(
                    sql: "INSERT INTO meeting_speaker (meeting_id, label, is_self, source_channel) VALUES (?, ?, ?, ?)",
                    arguments: [meetingID, speaker.label, speaker.isSelf, speaker.channel.rawValue])
                ids.append(db.lastInsertedRowID)
            }
            for (segmentID, index) in plan.assignments where ids.indices.contains(index) {
                try db.execute(
                    sql: "UPDATE meeting_segment SET speaker_id = ? WHERE id = ? AND meeting_id = ?",
                    arguments: [ids[index], segmentID, meetingID])
            }
            try db.execute(
                sql: "UPDATE meeting SET speaker_mode = ?, diarization_model_id = ? WHERE id = ?",
                arguments: [plan.mode.rawValue, diarizationModelID, meetingID])
        }
    }

    func speakers(meetingID: Int64) throws -> [SpeakerRow] {
        try read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, label, is_self, source_channel FROM meeting_speaker WHERE meeting_id = ? ORDER BY id",
                arguments: [meetingID]
            ).compactMap { row -> SpeakerRow? in
                let name: String = row["source_channel"]
                guard let channel = AudioChannel(rawValue: name) else { return nil }
                return SpeakerRow(id: row["id"], label: row["label"], isSelf: row["is_self"], channel: channel)
            }
        }
    }

    func speakerMode(of meetingID: Int64) throws -> SpeakerMode? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT speaker_mode FROM meeting WHERE id = ?", arguments: [meetingID])
                .flatMap(SpeakerMode.init(rawValue:))
        }
    }

    func diarizationModelID(of meetingID: Int64) throws -> String? {
        try read { db in
            try String.fetchOne(
                db, sql: "SELECT diarization_model_id FROM meeting WHERE id = ?", arguments: [meetingID])
        }
    }

    /// "To ja": makes this speaker the one `is_self` speaker of its meeting. A speaker still named by the
    /// default ("Mówca N") becomes "Ja"; one the user renamed keeps its name. The speaker who was "Ja" before
    /// loses the flag and, if still labelled "Ja", gets the lowest free "Mówca N". Notes that exist become
    /// `stale`, like after a rename. Returns false when the speaker does not exist **or when the meeting is in
    /// `channels` mode**: there the speakers are tracks ("Ja" / "Inni", or one neutral "Mówca 1"), not people,
    /// and moving the flag would break the track-to-label rule the banner promises. Renaming still works.
    @discardableResult
    func markSelf(speakerID: Int64) throws -> Bool {
        try write { db in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT meeting_id, label FROM meeting_speaker WHERE id = ?", arguments: [speakerID])
            else { return false }
            let meetingID: Int64 = row["meeting_id"]
            let label: String = row["label"]
            let mode = try String.fetchOne(
                db, sql: "SELECT speaker_mode FROM meeting WHERE id = ?", arguments: [meetingID])
            if mode == SpeakerMode.channels.rawValue { return false }
            let labels = try String.fetchAll(
                db, sql: "SELECT label FROM meeting_speaker WHERE meeting_id = ?", arguments: [meetingID])
            let previous = try Row.fetchAll(
                db, sql: "SELECT id, label FROM meeting_speaker WHERE meeting_id = ? AND is_self = 1 AND id != ?",
                arguments: [meetingID, speakerID])
            var taken = Set(labels)
            for old in previous {
                let oldID: Int64 = old["id"]
                let oldLabel: String = old["label"]
                if oldLabel == SpeakerLabels.me {
                    var number = 1
                    while taken.contains(SpeakerLabels.numbered(number)) { number += 1 }
                    let renamed = SpeakerLabels.numbered(number)
                    taken.insert(renamed)
                    try db.execute(
                        sql: "UPDATE meeting_speaker SET is_self = 0, label = ? WHERE id = ?",
                        arguments: [renamed, oldID])
                } else {
                    try db.execute(sql: "UPDATE meeting_speaker SET is_self = 0 WHERE id = ?", arguments: [oldID])
                }
            }
            let isDefault =
                label.hasPrefix(SpeakerLabels.numberedPrefix)
                && Int(label.dropFirst(SpeakerLabels.numberedPrefix.count)) != nil
            try db.execute(
                sql: "UPDATE meeting_speaker SET is_self = 1, label = ? WHERE id = ?",
                arguments: [isDefault ? SpeakerLabels.me : label, speakerID])
            try db.execute(
                sql: "UPDATE meeting SET notes_status = 'stale' WHERE id = ? AND notes_markdown IS NOT NULL",
                arguments: [meetingID])
            return true
        }
    }
}
