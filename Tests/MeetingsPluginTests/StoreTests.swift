import Foundation
import GRDB
import PouncePersistence
import Synchronization
import Testing

@testable import MeetingsPlugin

private func openStore() throws -> (MeetingsStore, TemporaryDirectory) {
    let directory = try TemporaryDirectory()
    return (try MeetingsStore.open(in: directory.url.appending(path: "meetings"), keys: testKeys()), directory)
}

private let day: TimeInterval = 86_400

@Suite struct MeetingsMigrationTests {
    @Test func aNewDatabaseHasExactlyTheSpecTablesAndIsEncryptedAndPrivate() throws {
        let (store, directory) = try openStore()
        let names = try store.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'view')")
        }
        for name in ["meeting", "meeting_speaker", "meeting_segment", "meeting_fts", "meeting_notes_fts"] {
            #expect(names.contains(name), "missing \(name)")
        }
        let triggers = try store.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
        }
        #expect(
            triggers == [
                "meeting_notes_ad", "meeting_notes_ai", "meeting_notes_au", "meeting_segment_ad",
                "meeting_segment_ai", "meeting_segment_au",
            ])
        let columns = try store.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(meeting)").map { $0["name"] as String }
        }
        #expect(
            columns == [
                "id", "uuid", "started_at", "ended_at", "duration_ms", "title", "source_bundle_id", "status",
                "speaker_mode", "languages", "speech_model_id", "diarization_model_id", "audio_state",
                "notes_markdown", "notes_status", "notes_prompt_version", "notes_model", "notes_dropped_count",
                "notes_generated_at",
            ])
        let speakerColumns = try store.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_speaker)").map { $0["name"] as String }
        }
        #expect(speakerColumns == ["id", "meeting_id", "label", "is_self", "source_channel"])
        let segmentColumns = try store.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(meeting_segment)").map { $0["name"] as String }
        }
        #expect(segmentColumns == ["id", "meeting_id", "channel", "start_ms", "end_ms", "speaker_id", "text"])
        let applied = try store.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(applied == ["v1-meetings"])
        #expect(try store.meetingCount() == 0)

        try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "parakeet-ultra")
        try store.close()
        let file = directory.url.appending(path: "meetings/meetings.sqlite")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.url.appending(path: "meetings").path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        // Without the key the file is not a database.
        #expect(throws: (any Error).self) { _ = try DatabaseQueue(path: file.path) }
    }

    @Test func theFileDoesNotHoldTheTextInTheClear() throws {
        let (store, directory) = try openStore()
        let id = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        try store.insertSegment(meetingID: id, channel: .mic, startMs: 0, end: 1_000, text: "recognisable secret")
        try store.setTitle(id, title: "Confidential roadmap")
        try store.close()
        let bytes = try Data(contentsOf: directory.url.appending(path: "meetings/meetings.sqlite"))
        #expect(bytes.range(of: Data("recognisable".utf8)) == nil)
        #expect(bytes.range(of: Data("Confidential".utf8)) == nil)
    }

    @Test func reopeningKeepsTheDataAndDoesNotMigrateTwice() throws {
        let directory = try TemporaryDirectory()
        let first = try MeetingsStore.open(in: directory.url, keys: testKeys())
        let id = try first.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        try first.insertSegment(meetingID: id, channel: .system, startMs: 0, end: 500, text: "hello")
        try first.close()
        let second = try MeetingsStore.open(in: directory.url, keys: testKeys())
        #expect(try second.meetingCount() == 1)
        #expect(try second.searchSegments("hel", limit: 5).count == 1)
        #expect(throws: (any Error).self) { _ = try MeetingsStore.open(in: directory.url, keys: testKeys(1)) }
    }

    @Test func aClosedStoreThrows() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        try store.close()
        try store.close()
        #expect(throws: MeetingsStoreError.self) { _ = try store.meetingCount() }
    }
}

extension MeetingsStore {
    @discardableResult
    fileprivate func insertSegment(
        meetingID: Int64, channel: AudioChannel, startMs: Int, end endMs: Int, text: String
    ) throws -> Int64 {
        try insertSegment(meetingID: meetingID, channel: channel, startMs: startMs, endMs: endMs, text: text)
    }
}

@Suite struct MeetingsFullTextTests {
    @Test func segmentsAreIndexedOnInsertUpdateAndDelete() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let meeting = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let first = try store.insertSegment(
            meetingID: meeting, channel: .mic, startMs: 0, end: 1, text: "budżet na jutro")
        let second = try store.insertSegment(
            meetingID: meeting, channel: .system, startMs: 2, end: 3, text: "plan roadmapy")
        #expect(try store.searchSegments("budż", limit: 10) == [first])
        #expect(try store.searchSegments("roadm", limit: 10) == [second])
        #expect(try store.searchSegments("budżet roadmapy", limit: 10).isEmpty)

        try store.setSegmentText(first, text: "harmonogram prac")
        #expect(try store.searchSegments("budżet", limit: 10).isEmpty)
        #expect(try store.searchSegments("harmon", limit: 10) == [first])

        try store.write { db in try db.execute(sql: "DELETE FROM meeting_segment WHERE id = ?", arguments: [second]) }
        #expect(try store.searchSegments("roadm", limit: 10).isEmpty)
        #expect(try store.searchSegments("harmon", limit: 10) == [first])
    }

    @Test func diacriticsAreFoldedSoZolcFindsZolc() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let meeting = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let id = try store.insertSegment(
            meetingID: meeting, channel: .mic, startMs: 0, end: 1, text: "Zażółć gęślą jaźń, żółć")
        #expect(try store.searchSegments("zolc", limit: 10) == [id])
        #expect(try store.searchSegments("ŻÓŁĆ", limit: 10) == [id])
        #expect(try store.searchSegments("gesla", limit: 10) == [id])
        #expect(try store.searchSegments("jazn", limit: 10) == [id])
        let other = try store.insertSegment(
            meetingID: meeting, channel: .mic, startMs: 2, end: 3, text: "Łódź Øresund Đakovo")
        #expect(try store.searchSegments("lodz", limit: 10) == [other])
        #expect(try store.searchSegments("łódź", limit: 10) == [other])
        #expect(try store.searchSegments("oresund dakovo", limit: 10) == [other])
        let indexed = try store.read { db in
            try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'meeting_fts'")
        }
        #expect(indexed?.contains("remove_diacritics 2") == true)
    }

    @Test func titlesAndNotesAreIndexedOnInsertUpdateAndDelete() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        #expect(try store.searchNotes("anything", limit: 10).isEmpty)

        try store.setTitle(id, title: "Przegląd kwartalny")
        #expect(try store.searchNotes("kwart", limit: 10) == [id])
        #expect(try store.searchNotes("przeglad", limit: 10) == [id])

        try store.setNotes(id, markdown: "## Decyzje\n- Zatwierdzono budżet", status: .ok)
        #expect(try store.searchNotes("zatwierdz", limit: 10) == [id])
        #expect(try store.searchNotes("kwart", limit: 10) == [id])

        try store.setTitle(id, title: "Retrospektywa")
        #expect(try store.searchNotes("kwart", limit: 10).isEmpty)
        #expect(try store.searchNotes("retro", limit: 10) == [id])
        #expect(try store.searchNotes("budzet", limit: 10) == [id])

        // Other columns do not touch the index (the trigger fires on title and notes only) and nothing breaks.
        try store.setStatus(id, status: .ready, endedAt: Date(), durationMs: 5_000)
        #expect(try store.searchNotes("retro", limit: 10) == [id])

        try store.setNotes(id, markdown: nil, status: .none)
        #expect(try store.searchNotes("budzet", limit: 10).isEmpty)
        #expect(try store.searchNotes("retro", limit: 10) == [id])

        try store.deleteMeetings([id])
        #expect(try store.searchNotes("retro", limit: 10).isEmpty)
    }

    @Test func aMeetingCreatedWithATitleIsIndexedByTheInsertTrigger() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let id = try store.write { db -> Int64 in
            try db.execute(
                sql:
                    "INSERT INTO meeting (uuid, started_at, title, notes_markdown) VALUES ('t', 1, 'Tytuł zespołu', 'notatki')"
            )
            return db.lastInsertedRowID
        }
        #expect(try store.searchNotes("tytul", limit: 10) == [id])
        #expect(try store.searchNotes("notat", limit: 10) == [id])
    }
}

@Suite struct MeetingsCascadeTests {
    @Test func deletingAMeetingRemovesItsSpeakersSegmentsAndIndexEntries() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let doomed = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let kept = try store.insertMeeting(uuid: "b", startedAt: Date(), speechModelID: "m")
        let speaker = try store.insertSpeaker(meetingID: doomed, label: "Mówca 1", isSelf: false, channel: .system)
        try store.insertSegment(
            meetingID: doomed, channel: .system, startMs: 0, endMs: 1, text: "wspólne słowo", speakerID: speaker)
        try store.insertSegment(meetingID: doomed, channel: .mic, startMs: 2, endMs: 3, text: "drugie zdanie")
        try store.insertSegment(meetingID: kept, channel: .mic, startMs: 0, endMs: 1, text: "wspólne słowo zostaje")
        try store.setTitle(doomed, title: "Do usunięcia")
        #expect(try store.speakerCount(meetingID: doomed) == 1)
        #expect(try store.segmentCount(meetingID: doomed) == 2)

        try store.deleteMeetings([doomed])

        #expect(try store.meetingCount() == 1)
        #expect(try store.speakerCount(meetingID: doomed) == 0)
        #expect(try store.segmentCount(meetingID: doomed) == 0)
        #expect(try store.segmentCount() == 1)
        #expect(try store.searchSegments("drugie", limit: 10).isEmpty)
        #expect(try store.searchSegments("wspólne", limit: 10).count == 1)
        #expect(try store.searchNotes("usunięcia", limit: 10).isEmpty)
        // The index is consistent with its content (the folding view).
        try store.write { db in
            try db.execute(sql: "INSERT INTO meeting_fts(meeting_fts) VALUES ('integrity-check')")
            try db.execute(sql: "INSERT INTO meeting_notes_fts(meeting_notes_fts) VALUES ('integrity-check')")
        }
    }

    @Test func deletingASpeakerLeavesItsSegmentsWithoutAName() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let meeting = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let speaker = try store.insertSpeaker(meetingID: meeting, label: "Ja", isSelf: true, channel: .mic)
        let segment = try store.insertSegment(
            meetingID: meeting, channel: .mic, startMs: 0, endMs: 1, text: "tak", speakerID: speaker)
        try store.write { db in try db.execute(sql: "DELETE FROM meeting_speaker WHERE id = ?", arguments: [speaker]) }
        let owner = try store.read { db in
            try Int64?.fetchOne(db, sql: "SELECT speaker_id FROM meeting_segment WHERE id = ?", arguments: [segment])
        }
        #expect(owner == .some(nil))
        #expect(try store.segmentCount() == 1)
    }

    @Test func aSegmentNeedsAnExistingMeeting() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        #expect(throws: (any Error).self) {
            try store.insertSegment(meetingID: 999, channel: .mic, startMs: 0, endMs: 1, text: "orphan")
        }
    }

    @Test func renamingASpeakerMarksNotesStaleOnlyWhenThereAreNotes() throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let withNotes = try store.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let withoutNotes = try store.insertMeeting(uuid: "b", startedAt: Date(), speechModelID: "m")
        let first = try store.insertSpeaker(meetingID: withNotes, label: "Mówca 1", isSelf: false, channel: .system)
        let second = try store.insertSpeaker(meetingID: withoutNotes, label: "Mówca 1", isSelf: false, channel: .system)
        try store.setNotes(withNotes, markdown: "notatki", status: .ok)

        try store.renameSpeaker(first, label: "Anna")
        try store.renameSpeaker(second, label: "Piotr")

        #expect(try store.notesStatus(of: withNotes) == .stale)
        #expect(try store.notesStatus(of: withoutNotes) == NotesStatus.none)
    }
}

@Suite struct MeetingsRetentionTests {
    private func populated() throws -> (MeetingsStore, TemporaryDirectory, now: Date) {
        let (store, directory) = try openStore()
        let now = Date(timeIntervalSince1970: 100 * day)
        let old = try store.insertMeeting(uuid: "old", startedAt: now.addingTimeInterval(-91 * day), speechModelID: "m")
        try store.setStatus(old, status: .ready)
        let edge = try store.insertMeeting(
            uuid: "edge", startedAt: now.addingTimeInterval(-89 * day), speechModelID: "m")
        try store.setStatus(edge, status: .ready)
        let interrupted = try store.insertMeeting(
            uuid: "interrupted", startedAt: now.addingTimeInterval(-120 * day), speechModelID: "m")
        try store.setStatus(interrupted, status: .incomplete)
        _ = try store.insertMeeting(uuid: "running", startedAt: now.addingTimeInterval(-200 * day), speechModelID: "m")
        try store.insertSegment(meetingID: old, channel: .mic, startMs: 0, endMs: 1, text: "stare")
        return (store, directory, now)
    }

    @Test func theCutoffDeletesOldMeetingsButNotActiveOnes() throws {
        let (store, directory, now) = try populated()
        defer { withExtendedLifetime(directory) {} }
        let deleted = try store.applyRetention(cutoff: now.addingTimeInterval(-90 * day))
        #expect(Set(deleted) == ["old", "interrupted"])
        #expect(try store.meetingCount() == 2)
        #expect(try store.segmentCount() == 0)
        #expect(try store.searchSegments("stare", limit: 5).isEmpty)
    }

    @Test func theJobUsesTheConfiguredDaysAndNeverDeletesWhenUnlimited() async throws {
        let (store, directory, now) = try populated()
        defer { withExtendedLifetime(directory) {} }
        let spool = RecordingSpool()
        let job = await RetentionJob(
            clock: ContinuousClock(), now: { now }, spool: spool, logger: .init(subsystem: "t", category: "t"))

        let none = await job.run(store: store, policy: .init(retentionDays: 0, orphanAudioDays: 7))
        #expect(none == 0)
        #expect(try store.meetingCount() == 4)
        #expect(spool.state.withLock { $0.removedForMeetings }.isEmpty)
        // Expired spools of interrupted meetings go even when meetings are kept for ever.
        #expect(spool.state.withLock { $0.olderThanCutoffs } == [now.addingTimeInterval(-7 * day)])

        let thirty = await job.run(store: store, policy: .init(retentionDays: 30, orphanAudioDays: 7))
        #expect(thirty == 3)
        #expect(Set(spool.state.withLock { $0.removedForMeetings }) == ["old", "edge", "interrupted"])
        #expect(try store.meetingCount() == 1)
    }

    @Test func theChoicesAreTheSpecsAndTheDefaultIs90() {
        #expect(MeetingsSettings.retentionDayChoices == [7, 30, 90, 180, 365, 0])
        #expect(MeetingsSettings.defaultRetentionDays == 90)
        #expect(RetentionJob.Policy(retentionDays: 0, orphanAudioDays: 7).cutoff(now: Date()) == nil)
    }

    @Test func vacuumRunsAtMostOncePerDay() async throws {
        let (store, directory) = try openStore()
        defer { withExtendedLifetime(directory) {} }
        let clock = Mutex(Date(timeIntervalSince1970: 100 * day))
        let job = await RetentionJob(
            clock: ContinuousClock(), now: { clock.withLock { $0 } }, logger: .init(subsystem: "t", category: "t"))
        let policy = RetentionJob.Policy(retentionDays: 30, orphanAudioDays: 7)

        func addOldMeeting(_ uuid: String) throws {
            let id = try store.insertMeeting(
                uuid: uuid, startedAt: clock.withLock { $0 }.addingTimeInterval(-40 * day), speechModelID: "m")
            try store.setStatus(id, status: .ready)
        }

        try addOldMeeting("a")
        #expect(await job.run(store: store, policy: policy) == 1)
        let first = await job.lastVacuum
        #expect(first == clock.withLock { $0 })

        clock.withLock { $0 = $0.addingTimeInterval(3_600) }
        try addOldMeeting("b")
        #expect(await job.run(store: store, policy: policy) == 1)
        #expect(await job.lastVacuum == first)

        clock.withLock { $0 = $0.addingTimeInterval(25 * 3_600) }
        try addOldMeeting("c")
        #expect(await job.run(store: store, policy: policy) == 1)
        #expect(await job.lastVacuum == clock.withLock { $0 })
    }
}
