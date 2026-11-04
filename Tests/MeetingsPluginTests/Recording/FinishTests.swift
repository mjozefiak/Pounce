import Foundation
import GRDB
import PounceKit
import PounceSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

private let words: [Int: String] = [
    11: "Pierwsza wypowiedź", 12: "Druga wypowiedź", 21: "Dzisiaj omawiamy plan wdrożenia nowej wersji",
    22: "Dzisiaj omawiamy plan wdrożenia nowej wersji",
]

private func mic() -> TrackScript { .build([(1, 11, 3), (4, 12, 3)], tail: 1) }  // 11: 1-4 s, 12: 8-11 s, 12 s

private final class EventBox: Sendable {
    private let items = Mutex<[ResumeEvent]>([])
    var all: [ResumeEvent] { items.withLock { $0 } }
    func add(_ event: ResumeEvent) { items.withLock { $0.append(event) } }
}

@MainActor
private func collect(_ handle: MeetingFinishHandle) async -> (events: [ResumeEvent], outcome: ResumeOutcome) {
    var events: [ResumeEvent] = []
    for await event in handle.events { events.append(event) }
    return (events, await handle.outcome)
}

@MainActor
@Suite struct FinishTests {
    @Test func finishingAnIncompleteMeetingTranscribesTheRestAssignsSpeakersAndDeletesTheSpool() async throws {
        let rig = try RecoveryRig(texts: words)
        let micTrack = mic()
        let meeting = try rig.seed(.incomplete, mic: micTrack, stored: [(.mic, 16_000..<64_000, words[11]!)])
        let library = rig.library(resumer: rig.resumerFactory(mic: micTrack))
        library.open()
        let store = try #require(library.store)
        #expect(try store.status(of: meeting.id) == .incomplete)

        let handle = try #require(library.finish(meetingID: meeting.id))
        // The same meeting cannot be finished twice at once.
        #expect(library.finish(meetingID: meeting.id) == nil)
        let (events, outcome) = await collect(handle)

        #expect(outcome == .ready)
        #expect(events.first == .scanning(.mic))
        #expect(events.contains(.replaying(remaining: 1)))
        #expect(events.contains(.finalizing))
        #expect(events.last == .finished(.ready))
        #expect(try store.status(of: meeting.id) == .ready)
        #expect(try store.audioState(of: meeting.id) == .deleted)
        #expect(!rig.spoolExists(meeting.uuid))
        #expect(try rig.rows(library, meeting.id).map(\.text) == [words[11]!, words[12]!])
        #expect(rig.engine.heard == [12])
        #expect(
            rig.finalizations.calls == [.init(meetingID: meeting.id, statusDuringCall: .processing, spoolExisted: true)]
        )
        // A finished meeting cannot be finished again.
        #expect(library.finish(meetingID: meeting.id) == nil)
        #expect(library.finish(meetingID: 9_999) == nil)
    }

    @Test func cancellingKeepsWhatWasWrittenAndLaterRunsContinueWithoutDuplicates() async throws {
        let rig = try RecoveryRig(texts: words)
        let micTrack = mic()
        let meeting = try rig.seed(.incomplete, mic: micTrack)
        let library = rig.library(resumer: rig.resumerFactory(mic: micTrack))
        library.open()
        let store = try #require(library.store)
        rig.engine.gate.close()

        let handle = try #require(library.finish(meetingID: meeting.id))
        let events = Task { await collect(handle) }
        let engine = rig.engine
        #expect(await engine.transcribing.wait { engine.entered >= 1 })
        handle.cancel()
        engine.gate.open()
        let (_, outcome) = await events.value

        #expect(outcome == .cancelled)
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.segmentCount(meetingID: meeting.id) == 1)
        #expect(rig.finalizations.calls.isEmpty)

        let second = try #require(library.finish(meetingID: meeting.id))
        let (_, again) = await collect(second)
        #expect(again == .ready)
        #expect(try rig.rows(library, meeting.id).map(\.text) == [words[11]!, words[12]!])
        #expect(engine.heard == [11, 12])
    }

    @Test func aSegmentThatFailsKeepsTheMeetingIncompleteAndTheSpoolUntilARetrySucceeds() async throws {
        let rig = try RecoveryRig(texts: words)
        let micTrack = mic()
        let meeting = try rig.seed(.processing, mic: micTrack)
        rig.engine.fail(12, times: 1)
        let library = rig.library(resumer: rig.resumerFactory(mic: micTrack))
        library.open()
        let store = try #require(library.store)

        #expect(await eventually { (try? store.status(of: meeting.id)) == .incomplete })
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.audioState(of: meeting.id) == .spool)
        #expect(try rig.rows(library, meeting.id).map(\.text) == [words[11]!])
        #expect(rig.finalizations.calls.isEmpty)

        let handle = try #require(library.finish(meetingID: meeting.id))
        let (_, outcome) = await collect(handle)
        #expect(outcome == .ready)
        #expect(try rig.rows(library, meeting.id).map(\.text) == [words[11]!, words[12]!])
        #expect(!rig.spoolExists(meeting.uuid))
    }

    @Test func aDamagedSpoolMidwayKeepsTheMeetingIncomplete() async throws {
        let rig = try RecoveryRig(texts: words)
        let micTrack = mic()
        let meeting = try rig.seed(.recording, mic: micTrack)
        // Flip a byte inside the second frame (header 44 B, frame header 5 B, 64 000 B body, 16 B tag).
        let file = rig.spool.file(for: meeting.uuid, track: .mic)
        var bytes = try Data(contentsOf: file)
        bytes[44 + 5 + 64_000 + 16 + 5 + 100] ^= 0xFF
        try bytes.write(to: file)

        let library = rig.library(resumer: rig.resumerFactory(mic: micTrack))
        library.open()
        let store = try #require(library.store)
        #expect(try store.status(of: meeting.id) == .incomplete)
        let handle = try #require(library.finish(meetingID: meeting.id))
        let (_, outcome) = await collect(handle)
        // The audio before the damage was transcribed; the rest is lost, so the meeting is not claimed finished.
        #expect(outcome == .incomplete(.unfinished(1)))
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(rig.spoolExists(meeting.uuid))
        #expect(try store.segmentCount(meetingID: meeting.id) == 1)
    }

    @Test func aMicrophoneEchoOfTheSystemTrackIsDroppedWhenFinishing() async throws {
        let rig = try RecoveryRig(texts: words)
        let system = TrackScript.build([(2, 21, 3)], tail: 3)  // 2-5 s
        let micTrack = TrackScript.build([(2.5, 22, 3)], tail: 2.5)  // 2.5-5.5 s
        let meeting = try rig.seed(.incomplete, mic: micTrack, system: system)
        let library = rig.library(resumer: rig.resumerFactory(mic: micTrack, system: system))
        library.open()
        let handle = try #require(library.finish(meetingID: meeting.id))
        let (_, outcome) = await collect(handle)
        #expect(outcome == .ready)
        let rows = try rig.rows(library, meeting.id)
        #expect(rows.map(\.channel) == ["system"])
    }

    @Test func aMeetingWithoutReadableAudioIsClosedFromItsTranscriptWhenTheUserAsks() async throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(
            .processing, mic: mic(), stored: [(.mic, 16_000..<64_000, words[11]!)], writeSpool: false)
        let library = rig.library(resumer: rig.resumerFactory(mic: mic()))
        library.open()
        let store = try #require(library.store)
        #expect(try store.status(of: meeting.id) == .incomplete)
        #expect(try store.audioState(of: meeting.id) == .deleted)

        let (_, outcome) = await collect(try #require(library.finish(meetingID: meeting.id)))
        #expect(outcome == .ready)
        #expect(try store.status(of: meeting.id) == .ready)
        #expect(rig.finalizations.calls.count == 1)
        #expect(rig.engine.loads == 0)
    }

    @Test(.enabled(if: getuid() != 0, "root ignores file permissions"))
    func aSpoolThatTheDiskCannotAnswerChangesNothing() async throws {
        let rig = try RecoveryRig(texts: words)
        let meeting = try rig.seed(.incomplete, mic: mic())
        let library = rig.library(resumer: rig.resumerFactory(mic: mic()))
        library.open()
        let store = try #require(library.store)
        // A symlink in place of the file is "unreadable"; a directory with no read access is an I/O error.
        let directory = rig.spool.directory(for: meeting.uuid)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let (_, outcome) = await collect(try #require(library.finish(meetingID: meeting.id)))
        #expect(outcome == .unavailable)
        #expect(try store.status(of: meeting.id) == .incomplete)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #expect(rig.spoolExists(meeting.uuid))
    }
}
