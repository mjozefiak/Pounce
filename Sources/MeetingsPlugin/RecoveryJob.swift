import Foundation
import os

/// What one recovery pass did. Ids only: no text, no uuids.
struct RecoveryReport: Equatable, Sendable {
    /// `recording` or `processing` meetings that became `incomplete`.
    var incomplete: [Int64] = []
    /// Meetings with nothing left to build on.
    var failed: [Int64] = []
    /// `processing` meetings with a readable spool: finalization continues in the background; they stay
    /// `processing`, so neither retention nor "Dokończ" touches them meanwhile.
    var toResume: [RecoverableMeeting] = []
    /// Library writes that failed (the meeting keeps its status and is looked at again next time).
    var writeFailures = 0

    var changedLibrary: Bool { !incomplete.isEmpty || !failed.isEmpty }
}

/// Crash recovery, run once at activation **before** the retention job's first pass (spec step 1.7). The
/// library hands the report to `startRetention(after:)`, so the order is structural, not a convention: a
/// leftover spool must first become an `incomplete` meeting that the age-out sweep may look at (a spool with
/// no row, or a meeting still `recording`, is never swept).
///
/// Rules, by the state the app died in:
///
/// | status at start | spool | segments | result |
/// |---|---|---|---|
/// | `recording` | readable | any | `incomplete` (recording is never resumed: the writer cannot be reopened) |
/// | `recording` | absent / unreadable | > 0 | `incomplete` (`audio_state` = `deleted` when no file is left) |
/// | `recording` | absent / unreadable | 0 | `failed` |
/// | `processing` | readable | any | resumed in the background (`MeetingResumer`); `incomplete` when it cannot run |
/// | `processing` | absent / unreadable | > 0 | `incomplete` (completeness cannot be verified) |
/// | `processing` | absent / unreadable | 0 | `failed` |
/// | either | I/O error | any | treated as readable: `incomplete`, the spool is kept |
///
/// `failed` is therefore only "unreadable (or no) spool and zero segments"; whatever is in the library stays.
/// Nothing here ever deletes a spool: an unreadable one is left to age out (or to the library reset that
/// follows a recreated Keychain key). A meeting that becomes `incomplete` gets its `orphanAudioDays` clock
/// started now, so a long time with the app closed never costs the user the chance to finish it.
@MainActor
final class RecoveryJob {
    private let spool: SpoolStorage
    private let keys: MeetingKeys
    private let now: () -> Date
    private let logger: Logger

    init(spool: SpoolStorage, keys: MeetingKeys, now: @escaping () -> Date = { Date() }, logger: Logger) {
        self.spool = spool
        self.keys = keys
        self.now = now
        self.logger = logger
    }

    /// One synchronous pass. Cheap: it reads the first frame of each interrupted meeting's spool, nothing more.
    /// Running it again changes nothing (no meeting is `recording` or `processing` any more, except those
    /// still being resumed, which resolve the same way).
    func recover(store: MeetingsStore, canResume: Bool) -> RecoveryReport {
        var report = RecoveryReport()
        let meetings: [RecoverableMeeting]
        do {
            meetings = try store.recoverableMeetings(statuses: [.recording, .processing])
        } catch {
            logger.error("Recovery could not read the library")
            report.writeFailures += 1
            return report
        }
        for meeting in meetings {
            let condition = meeting.uuid.map { spool.condition(of: $0, keys: keys) } ?? .absent
            let readable = condition == .readable
            let usable = readable || condition == .indeterminate
            switch (meeting.status, usable) {
            case (.processing, true) where readable && canResume:
                report.toResume.append(meeting)
            case (_, true):
                apply(.incomplete, to: meeting, condition: condition, store: store, report: &report)
            default:
                let status: MeetingStatus = meeting.segmentCount > 0 ? .incomplete : .failed
                apply(status, to: meeting, condition: condition, store: store, report: &report)
            }
        }
        if !report.incomplete.isEmpty || !report.failed.isEmpty || !report.toResume.isEmpty {
            logger.notice(
                "Recovery: \(report.incomplete.count, privacy: .public) incomplete, \(report.failed.count, privacy: .public) failed, \(report.toResume.count, privacy: .public) to resume"
            )
        }
        return report
    }

    private func apply(
        _ status: MeetingStatus, to meeting: RecoverableMeeting, condition: SpoolCondition, store: MeetingsStore,
        report: inout RecoveryReport
    ) {
        do {
            let duration = max(meeting.durationMs, try store.lastSegmentEndMs(meetingID: meeting.id))
            try store.setStatus(
                meeting.id, status: status,
                endedAt: meeting.endedAt ?? meeting.startedAt.addingTimeInterval(Double(duration) / 1_000),
                durationMs: duration)
            if condition == .absent, meeting.audioState == .spool {
                try store.setAudioState(meeting.id, state: .deleted)
            }
        } catch {
            logger.error("Recovery could not update a meeting")
            report.writeFailures += 1
            return
        }
        if condition != .absent, let uuid = meeting.uuid { spool.touch(meeting: uuid, at: now()) }
        if status == .failed { report.failed.append(meeting.id) } else { report.incomplete.append(meeting.id) }
    }
}
