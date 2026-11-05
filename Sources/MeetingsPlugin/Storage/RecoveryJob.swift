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
    /// `ready` meetings whose spool was still on disk (a delete that never finished) and has now been removed.
    var leftoverSpoolsRemoved = 0
    /// Library writes that failed (the meeting keeps its status and is looked at again next time).
    var writeFailures = 0

    var changedLibrary: Bool { !incomplete.isEmpty || !failed.isEmpty }
}

/// Crash recovery, run once at activation **before** the retention job's first pass (spec step 1.7). The
/// library calls it from `open()` and only then starts the retention job, so the order is structural, not a
/// convention: a leftover spool must first become an `incomplete` meeting that the age-out sweep may look at
/// (a spool with no row, or a meeting still `recording`, is never swept).
///
/// A meeting that is **live in this process** (`liveMeetingIDs`: a recording or finalizing session that
/// survived a disable and re-enable of the plugin) is never touched. A `processing` meeting that keeps
/// failing to resume is tried `MeetingsStore.maximumResumeAttempts` times, then becomes `incomplete`.
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
    func recover(store: MeetingsStore, canResume: Bool, liveMeetingIDs: Set<Int64> = []) -> RecoveryReport {
        var report = RecoveryReport()
        let meetings: [RecoverableMeeting]
        do {
            meetings = try store.recoverableMeetings(statuses: [.recording, .processing])
        } catch {
            logger.error("Recovery could not read the library")
            report.writeFailures += 1
            return report
        }
        for meeting in meetings where !liveMeetingIDs.contains(meeting.id) {
            let condition = meeting.uuid.map { spool.condition(of: $0, keys: keys) } ?? .absent
            let readable = condition == .readable
            let usable = readable || condition == .indeterminate
            switch (meeting.status, usable) {
            case (.processing, true) where readable && canResume:
                guard let attempts = try? store.bumpResumeAttempts(meeting.id) else {
                    logger.error("Recovery could not count a resume attempt")
                    report.writeFailures += 1
                    continue
                }
                if attempts > MeetingsStore.maximumResumeAttempts {
                    logger.notice("Recovery gave up resuming a meeting after repeated attempts")
                    apply(.incomplete, to: meeting, condition: condition, store: store, report: &report)
                } else {
                    report.toResume.append(meeting)
                }
            case (_, true):
                apply(.incomplete, to: meeting, condition: condition, store: store, report: &report)
            default:
                let status: MeetingStatus = meeting.segmentCount > 0 ? .incomplete : .failed
                apply(status, to: meeting, condition: condition, store: store, report: &report)
            }
        }
        removeLeftovers(store: store, report: &report, liveMeetingIDs: liveMeetingIDs)
        if report.leftoverSpoolsRemoved > 0 || !report.incomplete.isEmpty || !report.failed.isEmpty
            || !report.toResume.isEmpty
        {
            logger.notice(
                "Recovery: \(report.incomplete.count, privacy: .public) incomplete, \(report.failed.count, privacy: .public) failed, \(report.toResume.count, privacy: .public) to resume, \(report.leftoverSpoolsRemoved, privacy: .public) leftover spools"
            )
        }
        return report
    }

    /// A `ready` meeting never needs its audio: a spool still there is a delete that was interrupted.
    private func removeLeftovers(store: MeetingsStore, report: inout RecoveryReport, liveMeetingIDs: Set<Int64>) {
        guard let leftovers = try? store.readyMeetingsWithSpool() else { return }
        for leftover in leftovers where !liveMeetingIDs.contains(leftover.id) {
            guard spool.removeConfirmed(meeting: leftover.uuid, keys: keys) else { continue }
            if (try? store.setAudioState(leftover.id, state: .deleted)) != nil {
                report.leftoverSpoolsRemoved += 1
            } else {
                report.writeFailures += 1
            }
        }
    }

    private func apply(
        _ status: MeetingStatus, to meeting: RecoverableMeeting, condition: SpoolCondition, store: MeetingsStore,
        report: inout RecoveryReport
    ) {
        do {
            let duration = max(meeting.durationMs, try store.lastSegmentEndMs(meetingID: meeting.id))
            // One write: a crash between two could leave `incomplete` meetings that claim audio they lack.
            try store.setRecovered(
                meeting.id, status: status,
                endedAt: meeting.endedAt ?? meeting.startedAt.addingTimeInterval(Double(duration) / 1_000),
                durationMs: duration, audioDeleted: condition == .absent && meeting.audioState == .spool)
        } catch {
            logger.error("Recovery could not update a meeting")
            report.writeFailures += 1
            return
        }
        if condition != .absent, let uuid = meeting.uuid { spool.touch(meeting: uuid, at: now()) }
        if status == .failed { report.failed.append(meeting.id) } else { report.incomplete.append(meeting.id) }
    }
}
