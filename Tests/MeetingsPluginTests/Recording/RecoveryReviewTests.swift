import Foundation
import GRDB
import LintelKit
import LintelPersistence
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

private let words: [Int: String] = [11: "Pierwsza wypowiedź", 12: "Druga wypowiedź"]

/// Utterance 11 at 1-4 s, 12 at 8-11 s.
private func mic() -> TrackScript { .build([(1, 11, 3), (4, 12, 3)], tail: 1) }

@MainActor
private func finished(_ handle: MeetingFinishHandle) async -> ResumeOutcome {
    for await _ in handle.events {}
    return await handle.outcome
}

/// Review findings of step 1.7: retention vs. a running finish, confirmed deletes, unreadable spools, gaps,
/// live meetings, lingering tasks.
@MainActor
@Suite struct RecoveryReviewTests {
    // MARK: M1

    @Test func theSweepAndTheRetentionDeleteLeaveAMeetingThatIsBeingFinished() async throws {
        let rig = try RecoveryRig(texts: words)
        rig.harness.settings.setValue(.integer(7), forKey: "plugins.meetings.retentionDays")
        let track = mic()
        let meeting = try rig.seed(.incomplete, mic: track)
        // The spool is one hour past the seven days, the meeting is far past the retention.
        let edge = RecoveryRig.now.addingTimeInterval(-7 * RecoveryRig.day - 3_600)
        try rig.age(meeting.uuid, to: edge)
        let library = rig.library(resumer: rig.resumerFactory(mic: track))
        library.open()
        let store = try #require(library.store)
        rig.engine.gate.close()

        let handle = try #require(library.finish(meetingID: meeting.id))
        let engine = rig.engine
        #expect(await engine.transcribing.wait { engine.entered >= 1 })
        #expect(try store.status(of: meeting.id) == .processing)

        #expect(await library.applyRetention() == 0)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.meetingCount() == 1)
        #expect(try rig.modificationDate(meeting.uuid) > edge)

        engine.gate.open()
        #expect(await finished(handle) == .ready)
        #expect(!rig.spoolExists(meeting.uuid))
        // Once ready, the old meeting is retention's like any other.
        #expect(await library.applyRetention() == 1)
        library.close()
    }

    // MARK: M2

    @Test(.enabled(if: getuid() != 0, "root ignores file permissions"))
    func audioIsMarkedDeletedOnlyWhenTheRemovalIsConfirmed() async throws {
        let rig = try RecoveryRig(texts: words)
        let track = mic()
        let meeting = try rig.seed(.incomplete, mic: track)
        let library = rig.library(resumer: rig.resumerFactory(mic: track))
        library.open()
        let store = try #require(library.store)
        // No write access to the spool folder: its files cannot be removed.
        let root = rig.spool.directory(for: meeting.uuid)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }

        #expect(await finished(try #require(library.finish(meetingID: meeting.id))) == .ready)
        #expect(try store.status(of: meeting.id) == .ready)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.audioState(of: meeting.id) == .spool)
        library.close()

        // The next recovery pass retries the delete.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        library.open()
        #expect(library.lastRecovery?.leftoverSpoolsRemoved == 1)
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(try library.store?.audioState(of: meeting.id) == .deleted)
        library.close()
    }

    @Test func aReadyMeetingWhoseSpoolIsStillThereLosesItAtTheNextOpen() throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(.ready, mic: mic())
        let library = rig.library()
        library.open()
        #expect(library.lastRecovery?.leftoverSpoolsRemoved == 1)
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(try library.store?.audioState(of: meeting.id) == .deleted)
        library.close()
    }

    // MARK: M3

    @Test func finishingAnUnreadableSpoolKeepsItUntilTheUserAcceptsTheGap() async throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(
            .processing, mic: mic(), stored: [(.mic, 16_000..<64_000, words[11]!)], spoolKeys: try testKeys(77))
        let library = rig.library(resumer: rig.resumerFactory(mic: mic()))
        library.open()
        let store = try #require(library.store)
        #expect(try store.status(of: meeting.id) == .incomplete)

        let first = await finished(try #require(library.finish(meetingID: meeting.id)))
        #expect(first == .incomplete(.audioUnreadable))
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(try store.audioState(of: meeting.id) == .spool)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(rig.finalizations.calls.isEmpty)

        let second = await finished(try #require(library.finish(meetingID: meeting.id, acceptGap: true)))
        #expect(second == .ready)
        #expect(try store.status(of: meeting.id) == .ready)
        #expect(try store.hasAudioGap(meeting.id))
        #expect(try store.audioState(of: meeting.id) == .deleted)
        #expect(!rig.spoolExists(meeting.uuid))
        library.close()
    }

    // MARK: M4

    @Test func aZeroByteTrackNeverMakesFinishFailForeverWhenTheUserAcceptsTheGap() async throws {
        let rig = try RecoveryRig(texts: words)
        let track = mic()
        let meeting = try rig.seed(.incomplete, mic: track, system: .build([(2, nil, 0)], tail: 2))
        try Data().write(to: rig.spool.file(for: meeting.uuid, track: .system))
        let library = rig.library(resumer: rig.resumerFactory(mic: track))
        library.open()
        let store = try #require(library.store)

        let first = await finished(try #require(library.finish(meetingID: meeting.id)))
        #expect(first == .incomplete(.unfinished(1)))
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.hasAudioGap(meeting.id) == false)

        let second = await finished(try #require(library.finish(meetingID: meeting.id, acceptGap: true)))
        #expect(second == .ready)
        #expect(try store.status(of: meeting.id) == .ready)
        #expect(try store.hasAudioGap(meeting.id))
        #expect(try rig.rows(library, meeting.id).map(\.text) == [words[11]!, words[12]!])
        #expect(!rig.spoolExists(meeting.uuid))
        library.close()
    }

    @Test func aFailingDetectorIsNotCountedAsADamagedTrack() async throws {
        let rig = try RecoveryRig(texts: words)
        let track = mic()
        let meeting = try rig.seed(.incomplete, mic: track)
        let folder = rig.harness.directory.url.appending(path: "model")
        let engine = rig.engine
        let lease = rig.lease
        let library = rig.library(resumer: { store, keys, spool in
            MeetingResumer(
                store: store, keys: keys, spool: spool, makeVAD: { ThrowingVAD() },
                speech: { ResumeSpeech(engine: engine, modelID: "test-model", folder: folder) }, lease: lease,
                finalize: { _, _ in }, now: { RecoveryRig.now })
        })
        library.open()
        let outcome = await finished(try #require(library.finish(meetingID: meeting.id, acceptGap: true)))
        // Even with the gap accepted, a detector failure is not a gap: the meeting is not closed.
        #expect(outcome == .incomplete(.modelUnavailable(busy: false)))
        #expect(try library.store?.status(of: meeting.id) == .incomplete)
        #expect(rig.spoolExists(meeting.uuid))
        library.close()
    }

    // MARK: M5

    @Test func disablingAndReEnablingMidRecordingDoesNotFlipTheLiveMeeting() throws {
        let rig = try RecoveryRig(texts: words)
        let live = try rig.seed(.recording, mic: mic())
        let crashed = try rig.seed(.recording, mic: mic())
        let library = rig.library()
        library.registerLive(meetingID: live.id)
        library.open()
        let store = try #require(library.store)
        #expect(try store.status(of: live.id) == .recording)
        #expect(try store.status(of: crashed.id) == .incomplete)
        #expect(library.lastRecovery?.incomplete == [crashed.id])
        #expect(library.finish(meetingID: live.id) == nil)

        library.close()
        library.open()
        #expect(try library.store?.status(of: live.id) == .recording)
        #expect(rig.spoolExists(live.uuid))
        #expect(library.protectedMeetingIDs == [live.id])

        library.unregisterLive(meetingID: live.id)
        library.close()
        library.open()
        #expect(try library.store?.status(of: live.id) == .incomplete)
        library.close()
    }

    // MARK: M6

    @Test func closingCancelsAFinishAndASecondOpenResumesTheMeetingOnce() async throws {
        let rig = try RecoveryRig(texts: words)
        let track = mic()
        let meeting = try rig.seed(.incomplete, mic: track)
        let library = rig.library(resumer: rig.resumerFactory(mic: track))
        library.open()
        rig.engine.gate.close()
        let handle = try #require(library.finish(meetingID: meeting.id))
        let engine = rig.engine
        #expect(await engine.transcribing.wait { engine.entered >= 1 })

        library.close()
        library.open()
        let store = try #require(library.store)
        #expect(library.lastRecovery?.toResume.map(\.id) == [meeting.id])
        engine.gate.open()

        let old = await finished(handle)
        #expect(old != .ready)
        #expect(await eventually { (try? store.status(of: meeting.id)) == .ready })
        #expect(try rig.rows(library, meeting.id).map(\.text) == [words[11]!, words[12]!])
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(rig.finalizations.calls.count == 1)
        library.close()
    }

    // MARK: Lows

    @Test func aProcessingMeetingThatKeepsFailingToResumeBecomesIncompleteAfterThreeTries() throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(.processing, mic: mic())
        let store = try #require(rig.seedStoreForTests)
        let job = RecoveryJob(
            spool: rig.spool, keys: rig.keys, now: { RecoveryRig.now }, logger: rig.harness.context.logger)
        for attempt in 1...MeetingsStore.maximumResumeAttempts {
            let report = job.recover(store: store, canResume: true)
            #expect(report.toResume.map(\.id) == [meeting.id], "attempt \(attempt)")
            #expect(try store.status(of: meeting.id) == .processing)
        }
        let last = job.recover(store: store, canResume: true)
        #expect(last.toResume.isEmpty)
        #expect(last.incomplete == [meeting.id])
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(rig.spoolExists(meeting.uuid))
    }

    @Test func statusAndAudioStateAreWrittenInOneTransaction() throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(
            .recording, mic: mic(), stored: [(.mic, 16_000..<64_000, words[11]!)], writeSpool: false)
        let store = try #require(rig.seedStoreForTests)
        try store.write { db in
            try db.execute(
                sql: "CREATE TRIGGER ro BEFORE UPDATE OF audio_state ON meeting BEGIN SELECT RAISE(ABORT, 'ro'); END")
        }
        let job = RecoveryJob(
            spool: rig.spool, keys: rig.keys, now: { RecoveryRig.now }, logger: rig.harness.context.logger)
        let report = job.recover(store: store, canResume: false)
        #expect(report.writeFailures == 1)
        #expect(try store.status(of: meeting.id) == .recording)
        #expect(try store.audioState(of: meeting.id) == .spool)
    }

    @Test func rangesAreKnownWhenStoredSegmentsCoverAtLeastHalfOfThem() {
        let rate = AudioFormat.sampleRate
        let range = 0..<(4 * rate)  // 0-4000 ms
        func missing(_ stored: [(start: Int, end: Int)]) -> Bool {
            !MeetingResumer.uncovered([range], by: stored).isEmpty
        }
        #expect(missing([]))
        #expect(!missing([(0, 4_000)]))
        #expect(!missing([(0, 2_000)]))  // exactly half counts as known
        #expect(missing([(0, 1_999)]))
        #expect(!missing([(1_000, 3_000)]))
        #expect(missing([(3_000, 6_000)]))  // a quarter
        #expect(!missing([(0, 1_000), (3_000, 4_000)]))  // two segments add up to half
        #expect(missing([(0, 1_000), (3_500, 4_000)]))
        #expect(MeetingResumer.uncovered([5..<5], by: []).count == 1)  // an empty range is never "covered"
        #expect(MeetingResumer.uncovered([], by: [(0, 100)]).isEmpty)
    }

    @Test func aWipedKeychainNextToAValidSpoolWithoutALibraryStillDeletesTheUnreadableSpool() throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(.recording, mic: mic())
        rig.closeSeed()
        try rig.harness.keychain.deleteGenericPassword(service: "com.lintelapp.meetings", account: "master-key")
        // The database is gone as well: no archive, a fresh library, but the old spool is still on disk.
        try FileManager.default.removeItem(at: rig.pluginDirectory.appending(path: MeetingsStore.fileName))
        let library = rig.library()
        library.open()
        #expect(library.status == .ready)
        #expect(library.resetArchive == nil)
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(library.lastRecovery == RecoveryReport())
        // A normal second open (the key now exists) does not delete anything again.
        let other = UUID()
        _ = try SpoolWriter.create(
            in: rig.spool, meeting: other, track: .mic, keys: rig.keys, freeSpace: { _ in .max })
        library.close()
        library.open()
        #expect(rig.spoolExists(other))
        library.close()
    }
}

private struct ThrowingVAD: VoiceActivityDetector {
    struct Failure: Error {}
    func process(_ samples: [Float]) async throws -> [VADEvent] { throw Failure() }
}
