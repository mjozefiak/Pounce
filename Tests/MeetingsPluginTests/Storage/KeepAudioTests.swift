import Foundation
import GRDB
import Testing

@testable import MeetingsPlugin

private let day: TimeInterval = 86_400

@MainActor
@Suite struct KeepAudioTests {
    // MARK: Setting

    @Test func keepAudioIsOffByDefaultAndKeepsThirtyDays() throws {
        let harness = try MeetingsHarness()
        #expect(harness.meetingsSettings.keepAudio == false)
        #expect(harness.meetingsSettings.keptAudioDays == 30)
        harness.meetingsSettings.setKeepAudio(true)
        #expect(harness.meetingsSettings.keepAudio)
    }

    // MARK: Three ways to ready

    @Test func offDeletesTheSpoolWhenASessionEndsReady() async throws {
        let rig = try SessionRig(texts: [11: "Hello"])
        let (id, uuid) = try await recordHello(rig, keepAudio: false)
        #expect(try rig.store.audioState(of: id) == .deleted)
        #expect(!FileManager.default.fileExists(atPath: rig.spool.directory(for: uuid).path))
    }

    @Test func onKeepsTheSpoolWhenASessionEndsReady() async throws {
        let rig = try SessionRig(texts: [11: "Hello"])
        let (id, uuid) = try await recordHello(rig, keepAudio: true)
        #expect(try rig.store.status(of: id) == .ready)
        #expect(try rig.store.audioState(of: id) == .kept)
        #expect(FileManager.default.fileExists(atPath: rig.spool.directory(for: uuid).path))
    }

    @Test func onKeepsTheSpoolWhenAFinishedMeetingBecomesReady() async throws {
        let rig = try RecoveryRig(texts: [11: "Hello"])
        var micTrack = TrackScript()
        micTrack.silence(1)
        micTrack.say(11, seconds: 2)
        micTrack.silence(14)
        let meeting = try await rig.seed(.incomplete, mic: micTrack)
        let library = rig.library(resumer: rig.resumerFactory(mic: micTrack, keepAudio: true))
        library.open()
        let store = try #require(library.store)
        let handle = try #require(library.finish(meetingID: meeting.id))
        for await _ in handle.events {}
        #expect(await handle.outcome == .ready)
        #expect(try store.audioState(of: meeting.id) == .kept)
        #expect(rig.spoolExists(meeting.uuid))
        library.close()
    }

    @Test func recoveryKeepsALeftoverSpoolOnlyWhileKeepAudioIsOn() async throws {
        for keep in [false, true] {
            let rig = try RecoveryRig(texts: [:])
            let micTrack = TrackScript()
            let meeting = try await rig.seed(.ready, mic: micTrack)
            rig.harness.meetingsSettings.setKeepAudio(keep)
            let library = rig.library()
            library.open()
            let store = try #require(library.store)
            #expect(try store.audioState(of: meeting.id) == (keep ? .kept : .deleted))
            #expect(rig.spoolExists(meeting.uuid) == keep)
            library.close()
        }
    }

    @Test func recoveryDoesNotCountALeftoverWhoseFolderIsGoneAsKept() async throws {
        let rig = try RecoveryRig(texts: [:])
        let meeting = try await rig.seed(.ready, mic: TrackScript())
        try FileManager.default.removeItem(at: rig.spool.directory(for: meeting.uuid))
        rig.harness.meetingsSettings.setKeepAudio(true)
        let library = rig.library()
        library.open()
        let store = try #require(library.store)
        #expect(try store.audioState(of: meeting.id) == .deleted)
        #expect(try store.keptAudioCount() == 0)
        library.close()
    }

    // MARK: Expiry and deletion

    @Test func retentionLeavesTheKeptAudioOfALiveMeetingAlone() async throws {
        let now = Date(timeIntervalSince1970: 500 * day)
        let harness = try MeetingsHarness()
        let spool = RecordingSpool(existing: ["held"])
        let library = harness.library(now: { now }, spool: spool)
        library.open()
        let store = try #require(library.store)
        let id = try store.insertMeeting(
            uuid: "held", startedAt: now.addingTimeInterval(-40 * day), speechModelID: "m", status: .ready)
        try store.setStatus(id, status: .ready, endedAt: now.addingTimeInterval(-40 * day), durationMs: 1_000)
        try store.setAudioState(id, state: .kept)
        library.registerLive(meetingID: id)
        _ = await library.applyRetention()
        #expect(try store.audioState(of: id) == .kept)
        #expect(spool.state.withLock { $0.existing } == ["held"])
        library.unregisterLive(meetingID: id)
        _ = await library.applyRetention()
        #expect(try store.audioState(of: id) == .deleted)
        #expect(spool.state.withLock { $0.existing }.isEmpty)
    }

    @Test func retentionRemovesKeptAudioOlderThanTheDaysAndNothingElse() async throws {
        let now = Date(timeIntervalSince1970: 500 * day)
        let harness = try MeetingsHarness()
        let spool = RecordingSpool(existing: ["old", "fresh", "plain"])
        let library = harness.library(now: { now }, spool: spool)
        library.open()
        let store = try #require(library.store)
        func add(_ uuid: String, age: Double, audio: AudioState) throws -> Int64 {
            let id = try store.insertMeeting(
                uuid: uuid, startedAt: now.addingTimeInterval(-age * day), speechModelID: "m", status: .ready)
            try store.setStatus(
                id, status: .ready, endedAt: now.addingTimeInterval(-age * day), durationMs: 1_000)
            try store.setAudioState(id, state: audio)
            return id
        }
        let old = try add("old", age: 31, audio: .kept)
        let fresh = try add("fresh", age: 29, audio: .kept)
        let plain = try add("plain", age: 31, audio: .spool)
        _ = await library.applyRetention()
        #expect(try store.audioState(of: old) == .deleted)
        #expect(try store.audioState(of: fresh) == .kept)
        #expect(try store.audioState(of: plain) == .spool)
        #expect(spool.state.withLock { $0.existing } == ["fresh", "plain"])
        #expect(try store.meetingCount() == 3)
    }

    @Test func deletingAMeetingRemovesItsKeptSpool() throws {
        let harness = try MeetingsHarness()
        let spool = RecordingSpool(existing: ["kept"])
        let library = harness.library(spool: spool)
        library.open()
        let store = try #require(library.store)
        let id = try store.insertMeeting(uuid: "kept", startedAt: Date(), speechModelID: "m", status: .ready)
        try store.setAudioState(id, state: .kept)
        #expect(try store.deleteMeeting(id, spool: spool))
        #expect(spool.state.withLock { $0.existing }.isEmpty)
    }

    // MARK: Privacy

    @Test func deleteKeptRecordingsRemovesOnlyKeptAudioAndKeepsTheTranscripts() throws {
        let harness = try MeetingsHarness()
        let library = harness.library()
        library.open()
        let store = try #require(library.store)
        let kept = try store.insertMeeting(uuid: "k", startedAt: Date(), speechModelID: "m", status: .ready)
        try store.setAudioState(kept, state: .kept)
        let other = try store.insertMeeting(uuid: "o", startedAt: Date(), speechModelID: "m", status: .incomplete)
        let privacy = MeetingsPrivacyActions(
            library: library, spool: SpoolStorage(pluginDirectory: harness.pluginDirectory)
        ) {}
        #expect(privacy.keptRecordingCount() == 1)
        let report = try privacy.deleteKeptRecordings()
        #expect(report == PrivacyReport(removed: 1, failed: 0))
        #expect(try store.audioState(of: kept) == .deleted)
        #expect(try store.audioState(of: other) == .spool)
        #expect(try store.meetingCount() == 2)
        #expect(privacy.keptRecordingCount() == 0)
    }

    @Test func deleteKeptRecordingsRefusesALiveMeetingAndAClosedLibrary() throws {
        let harness = try MeetingsHarness()
        let library = harness.library()
        let spool = SpoolStorage(pluginDirectory: harness.pluginDirectory)
        let closed = MeetingsPrivacyActions(library: library, spool: spool) {}
        #expect(try closed.deleteKeptRecordings() == PrivacyReport(removed: 0))
        #expect(closed.keptRecordingCount() == 0)
        library.open()
        let store = try #require(library.store)
        let uuid = UUID()
        let id = try store.insertMeeting(
            uuid: SpoolStorage.name(of: uuid), startedAt: Date(), speechModelID: "m", status: .ready)
        try store.setAudioState(id, state: .kept)
        _ = try spool.prepare(meeting: uuid)
        library.registerLive(meetingID: id)
        let privacy = MeetingsPrivacyActions(library: library, spool: spool) {}
        #expect(try privacy.deleteKeptRecordings() == PrivacyReport(removed: 0, failed: 0))
        #expect(try store.audioState(of: id) == .kept)
        #expect(spool.hasSpool(forMeeting: SpoolStorage.name(of: uuid)))
        #expect(privacy.keptRecordingCount() == 1)
    }

    // MARK: Compatibility

    @Test func theKeptStateSurvivesAReadAndAnUnknownValueReadsAsDeleted() throws {
        let harness = try MeetingsHarness()
        let library = harness.library()
        library.open()
        let store = try #require(library.store)
        let id = try store.insertMeeting(uuid: "u", startedAt: Date(), speechModelID: "m", status: .ready)
        try store.setAudioState(id, state: .kept)
        #expect(try store.loadDocument(id: id)?.audioState == .kept)
        try store.write { db in try db.execute(sql: "UPDATE meeting SET audio_state = 'from-the-future'") }
        #expect(try store.loadDocument(id: id)?.audioState == .deleted)
        #expect(try store.audioState(of: id) == nil)
    }

    // MARK: Helpers

    private func recordHello(_ rig: SessionRig, keepAudio: Bool) async throws -> (Int64, UUID) {
        var mic = TrackScript()
        mic.silence(1)
        mic.say(11, seconds: 2)
        mic.silence(14)
        let uuid = UUID()
        let session = rig.session(mic: mic, system: nil, uuid: uuid, withSystem: false, keepAudio: keepAudio)
        let id = try await session.start()
        rig.mic.push(mic.samples)
        rig.mic.end()
        let outcome = await session.finish()
        #expect(outcome.result == .ready)
        return (id, uuid)
    }
}
