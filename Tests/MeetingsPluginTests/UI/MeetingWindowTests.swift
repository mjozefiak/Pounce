import Foundation
import GRDB
import LintelKit
import Synchronization
import Testing

@testable import MeetingsPlugin

// MARK: Fakes

@MainActor final class RecordingPasteboard: PasteboardClient {
    nonisolated init() {}
    private(set) var strings: [String] = []
    private(set) var written: [[PasteboardItem]] = []
    var changeCount: Int { strings.count }
    func string() -> String? { strings.last }
    func setString(_ string: String) -> Int {
        strings.append(string)
        return strings.count
    }
    func write(_ items: [PasteboardItem]) -> Int {
        written.append(items)
        let text = items.first?.data(for: PasteboardRepresentation.plainTextType).flatMap {
            String(data: $0, encoding: .utf8)
        }
        return setString(text ?? "")
    }
}

@MainActor final class FakeFileSaver: FileSaver {
    nonisolated init() {}
    var saved: [(contents: String, name: String)] = []
    var cancels = false
    var fails = false
    func save(_ contents: String, suggestedName: String) async throws -> URL? {
        if fails { throw CocoaError(.fileWriteUnknown) }
        if cancels { return nil }
        saved.append((contents, suggestedName))
        return URL(filePath: "/tmp/never-written.md")
    }
}

final class Box<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>
    init(_ value: Value) { storage = Mutex(value) }
    func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R { storage.withLock { body(&$0) } }
}

struct WindowRig {
    let store: MeetingsStore
    let directory: TemporaryDirectory
    let meetingID: Int64
    let me: Int64
    let anna: Int64
    let spool = RecordingSpool(existing: ["meeting-uuid"])

    init(
        status: MeetingStatus = .ready, mode: SpeakerMode = .diarized, notes: String? = nil,
        segments: Bool = true
    ) throws {
        directory = try TemporaryDirectory()
        store = try MeetingsStore.open(in: directory.url.appending(path: "meetings"), keys: testKeys())
        let meetingID = try store.insertMeeting(
            uuid: "meeting-uuid", startedAt: ExportFixtures.started, speechModelID: "m", status: status)
        self.meetingID = meetingID
        try store.write { db in
            try db.execute(
                sql: "UPDATE meeting SET speaker_mode = ?, duration_ms = 90000 WHERE id = ?",
                arguments: [mode.rawValue, meetingID])
        }
        let me = try store.insertSpeaker(meetingID: meetingID, label: "Mówca 1", isSelf: false, channel: .mic)
        let anna = try store.insertSpeaker(meetingID: meetingID, label: "Mówca 2", isSelf: false, channel: .system)
        self.me = me
        self.anna = anna
        if segments {
            try store.insertSegment(
                meetingID: meetingID, channel: .mic, startMs: 1000, endMs: 2000, text: "Dzień dobry", speakerID: me)
            try store.insertSegment(
                meetingID: meetingID, channel: .system, startMs: 3000, endMs: 4000, text: "Hello",
                speakerID: anna)
        }
        if let notes { try store.setNotes(meetingID, markdown: notes, status: .ok) }
    }
}

@MainActor
struct WindowHarness {
    let rig: WindowRig
    let pasteboard = RecordingPasteboard()
    let saver = FakeFileSaver()
    let model: MeetingWindowModel
    let deleted = Box(0)

    init(
        _ rig: WindowRig, finish: @escaping @MainActor (Int64, Bool) -> MeetingFinishHandle? = { _, _ in nil },
        regenerate: (@MainActor (Int64) -> Void)? = nil
    ) {
        self.rig = rig
        let deleted = deleted
        model = MeetingWindowModel(
            meetingID: rig.meetingID, store: rig.store, spool: rig.spool, pasteboard: pasteboard, saver: saver,
            finish: finish, regenerate: regenerate, onDeleted: { deleted.withLock { $0 += 1 } },
            labels: .english, timeZone: ExportFixtures.utc)
    }
}

// MARK: Store operations

@Suite struct MeetingWindowStoreTests {
    @Test func loadDocumentReturnsTheMeetingInTranscriptOrder() throws {
        let rig = try WindowRig(notes: "n")
        let document = try #require(try rig.store.loadDocument(id: rig.meetingID))
        #expect(document.speakers.map(\.label) == ["Mówca 1", "Mówca 2"])
        #expect(document.segments.map(\.text) == ["Dzień dobry", "Hello"])
        #expect(document.notesMarkdown == "n")
        #expect(try rig.store.loadDocument(id: 999) == nil)
    }

    @Test func renamingASpeakerMarksNotesStaleOnlyWhenThereAreNotes() throws {
        let with = try WindowRig(notes: "notes")
        try with.store.renameSpeaker(with.anna, label: "Anna")
        #expect(try with.store.notesStatus(of: with.meetingID) == .stale)
        #expect(try with.store.loadDocument(id: with.meetingID)?.speakers.last?.label == "Anna")

        let without = try WindowRig()
        try without.store.renameSpeaker(without.anna, label: "Anna")
        #expect(try without.store.notesStatus(of: without.meetingID) == NotesStatus.none)
    }

    @Test func renamingTheMeetingKeepsNotesCurrentAndABlankTitleClearsIt() throws {
        let rig = try WindowRig(notes: "notes")
        try rig.store.renameMeeting(rig.meetingID, title: "  Planning  ")
        #expect(try rig.store.loadDocument(id: rig.meetingID)?.title == "Planning")
        #expect(try rig.store.notesStatus(of: rig.meetingID) == .ok)
        try rig.store.renameMeeting(rig.meetingID, title: "   ")
        #expect(try rig.store.loadDocument(id: rig.meetingID)?.title == nil)
    }

    @Test func deletingCascadesAndRemovesTheSpool() throws {
        let rig = try WindowRig()
        let other = try rig.store.insertMeeting(uuid: "other", startedAt: Date(), speechModelID: "m", status: .ready)
        try rig.store.insertSegment(meetingID: other, channel: .mic, startMs: 0, endMs: 1, text: "keep")

        #expect(try rig.store.deleteMeeting(rig.meetingID, spool: rig.spool))

        #expect(try rig.store.loadDocument(id: rig.meetingID) == nil)
        #expect(try rig.store.speakerCount(meetingID: rig.meetingID) == 0)
        #expect(try rig.store.segmentCount(meetingID: rig.meetingID) == 0)
        #expect(try rig.store.segmentCount(meetingID: other) == 1)
        #expect(rig.spool.state.withLock { $0.removedForMeetings } == ["meeting-uuid"])
        #expect(try !rig.store.deleteMeeting(rig.meetingID, spool: rig.spool), "already gone")
    }

    @Test func deletingRemovesARealSpoolFolder() throws {
        let rig = try WindowRig(status: .incomplete)
        let uuid = UUID()
        try rig.store.write { db in
            try db.execute(
                sql: "UPDATE meeting SET uuid = ? WHERE id = ?", arguments: [uuid.uuidString, rig.meetingID])
        }
        let storage = SpoolStorage(pluginDirectory: rig.directory.url)
        let folder = try storage.prepare(meeting: uuid)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        try rig.store.deleteMeeting(rig.meetingID, spool: storage)

        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func aMeetingBeingRecordedOrProcessedCannotBeDeleted() throws {
        for status in [MeetingStatus.recording, .processing] {
            let rig = try WindowRig(status: status)
            #expect(throws: MeetingActionError.active) { try rig.store.deleteMeeting(rig.meetingID, spool: rig.spool) }
            #expect(try rig.store.loadDocument(id: rig.meetingID) != nil)
            #expect(rig.spool.state.withLock { $0.removedForMeetings }.isEmpty)
        }
    }
}

// MARK: Window model

@MainActor @Suite struct MeetingWindowModelTests {
    @Test func startsLoadingThenShowsTheMeeting() async throws {
        let harness = WindowHarness(try WindowRig())
        #expect(harness.model.phase == .loading)
        await harness.model.load()
        #expect(harness.model.phase == .loaded)
        #expect(harness.model.document?.segments.count == 2)
        #expect(harness.model.banners.isEmpty)
        #expect(!harness.model.isEmpty)
    }

    @Test func aMissingMeetingAndAnEmptyTranscriptAreTheirOwnStates() async throws {
        let rig = try WindowRig(segments: false)
        let empty = WindowHarness(rig)
        await empty.model.load()
        #expect(empty.model.isEmpty)
        #expect(!empty.model.canCopy && !empty.model.canSave)

        _ = try rig.store.deleteMeeting(rig.meetingID, spool: rig.spool)
        await empty.model.load()
        #expect(empty.model.phase == .missing)
    }

    @Test func aLongTranscriptLoads() async throws {
        let rig = try WindowRig(segments: false)
        try rig.store.write { db in
            for index in 0..<5_000 {
                try db.execute(
                    sql:
                        "INSERT INTO meeting_segment (meeting_id, channel, start_ms, end_ms, speaker_id, text) VALUES (?, 'mic', ?, ?, ?, 'x')",
                    arguments: [rig.meetingID, index * 1000, index * 1000 + 900, rig.me])
            }
        }
        let harness = WindowHarness(rig)
        await harness.model.load()
        #expect(harness.model.document?.segments.count == 5_000)
        #expect(harness.model.markdown()?.contains("[01:23:19] ") == true)
    }

    @Test func bannersFollowTheMeetingState() async throws {
        func banners(_ rig: WindowRig) async -> [MeetingWindowModel.Banner] {
            let harness = WindowHarness(rig)
            await harness.model.load()
            return harness.model.banners
        }
        #expect(try await banners(WindowRig(mode: .channels)) == [.speakersUnavailable])
        #expect(try await banners(WindowRig(status: .incomplete)) == [.incomplete(canFinish: true)])
        #expect(try await banners(WindowRig(status: .failed)) == [.failed])
        #expect(try await banners(WindowRig(status: .processing)) == [.processing])
        #expect(
            try await banners(WindowRig(status: .incomplete, mode: .channels)) == [
                .incomplete(canFinish: true), .speakersUnavailable,
            ])
        let stale = try WindowRig(notes: "n")
        try stale.store.renameSpeaker(stale.anna, label: "Anna")
        #expect(await banners(stale) == [.notesStale])

        let gone = try WindowRig(status: .incomplete)
        try gone.store.setAudioState(gone.meetingID, state: .deleted)
        #expect(await banners(gone) == [.incomplete(canFinish: false)])
    }

    @Test func renamingASpeakerWritesThroughAndMarksNotesStale() async throws {
        let rig = try WindowRig(notes: "notes")
        let harness = WindowHarness(rig)
        await harness.model.load()
        await harness.model.renameSpeaker(rig.anna, to: "  Anna  ")
        #expect(harness.model.document?.speakers.last?.label == "Anna")
        #expect(harness.model.banners == [.notesStale])

        await harness.model.renameSpeaker(rig.anna, to: "   ")
        #expect(harness.model.document?.speakers.last?.label == "Anna", "a blank name is ignored")
    }

    @Test func markSelfCallsTheStoreAndIsHiddenInChannelsMode() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        let anna = try #require(harness.model.speakers.last)
        #expect(harness.model.canMarkSelf(anna))
        await harness.model.markSelf(rig.anna)
        #expect(harness.model.document?.speakers.last?.isSelf == true)
        #expect(harness.model.document?.speakers.last?.label == "Ja")
        #expect(!harness.model.canMarkSelf(try #require(harness.model.speakers.last)), "already the user")

        let channels = try WindowRig(mode: .channels)
        let other = WindowHarness(channels)
        await other.model.load()
        #expect(other.model.speakers.allSatisfy { !other.model.canMarkSelf($0) })
        await other.model.markSelf(channels.anna)
        #expect(other.model.document?.speakers.allSatisfy { !$0.isSelf } == true)
    }

    @Test func renamingTheTitleUpdatesTheWindowTitle() async throws {
        let harness = WindowHarness(try WindowRig())
        await harness.model.load()
        #expect(harness.model.title.hasPrefix("Meeting") || harness.model.title.contains("2026"))
        await harness.model.renameTitle("Retro")
        #expect(harness.model.title == "Retro")
        await harness.model.renameTitle("")
        #expect(harness.model.document?.title == nil)
    }

    @Test func copyUsesThePasteboardPortOnlyOnTheExplicitAction() async throws {
        let harness = WindowHarness(try WindowRig(notes: "Notes body"))
        await harness.model.load()
        #expect(harness.pasteboard.strings.isEmpty, "loading never copies")
        harness.model.copyMarkdown()
        #expect(harness.pasteboard.strings.count == 1)
        let copied = try #require(harness.pasteboard.strings.first)
        #expect(copied.contains("Notes body"))
        #expect(copied.contains("[00:00:01] Mówca 1: Dzień dobry"))
        let types = try #require(harness.pasteboard.written.first?.first?.types)
        #expect(types.contains(PasteboardRepresentation.transientMarkerType))
        #expect(types.contains(PasteboardRepresentation.concealedMarkerType))
        #expect(!PasteboardRepresentation.markerTypes.isDisjoint(with: types), "Lintel's history skips it")
        #expect(harness.model.feedback == .copied)
    }

    @Test func saveGoesThroughTheFileSaver() async throws {
        let harness = WindowHarness(try WindowRig())
        await harness.model.load()
        await harness.model.renameTitle("Plan: Q1/Q2")
        await harness.model.saveMarkdown()
        #expect(harness.saver.saved.count == 1)
        #expect(harness.saver.saved.first?.name == "Plan Q1 Q2.md")
        #expect(harness.saver.saved.first?.contents == harness.model.markdown())
        #expect(harness.model.feedback == .saved)

        harness.saver.cancels = true
        await harness.model.saveMarkdown()
        #expect(harness.saver.saved.count == 1)
        harness.saver.cancels = false
        harness.saver.fails = true
        await harness.model.saveMarkdown()
        #expect(harness.model.feedback == .saveFailed)
    }

    @Test func regenerateIsDisabledWithAnExplanationUntilItIsWired() async throws {
        let harness = WindowHarness(try WindowRig())
        await harness.model.load()
        #expect(!harness.model.canRegenerate)
        #expect(harness.model.regenerateExplanation != nil)
        harness.model.regenerateNotes()

        let calls = Box<[Int64]>([])
        let rig = try WindowRig()
        let wired = WindowHarness(rig, regenerate: { id in calls.withLock { $0.append(id) } })
        await wired.model.load()
        #expect(wired.model.canRegenerate)
        #expect(wired.model.regenerateExplanation == nil)
        wired.model.regenerateNotes()
        #expect(calls.withLock { $0 } == [rig.meetingID])
    }

    @Test func finishRunsTheInjectedActionAndReloads() async throws {
        let rig = try WindowRig(status: .incomplete)
        let asked = Box<[Int64]>([])
        let harness = WindowHarness(rig) { id, _ in
            asked.withLock { $0.append(id) }
            try? rig.store.setStatus(id, status: .ready)
            let (events, continuation) = AsyncStream.makeStream(of: ResumeEvent.self)
            continuation.yield(.finalizing)
            continuation.finish()
            return MeetingFinishHandle(events: events, task: Task { .ready })
        }
        await harness.model.load()
        #expect(harness.model.banners == [.incomplete(canFinish: true)])
        await harness.model.finish()
        #expect(asked.withLock { $0 } == [rig.meetingID])
        #expect(harness.model.document?.status == .ready)
        #expect(harness.model.banners.isEmpty)
        #expect(!harness.model.isFinishing)
    }

    @Test func finishThatIsRefusedSaysSo() async throws {
        let harness = WindowHarness(try WindowRig(status: .incomplete))
        await harness.model.load()
        await harness.model.finish()
        #expect(harness.model.feedback == .finishUnavailable)
        #expect(harness.model.document?.status == .incomplete)
    }

    @Test func deleteNeedsConfirmationAndRemovesTheMeetingAndItsSpool() async throws {
        let rig = try WindowRig()
        let harness = WindowHarness(rig)
        await harness.model.load()
        harness.model.requestDelete()
        #expect(harness.model.isConfirmingDelete)
        #expect(try rig.store.loadDocument(id: rig.meetingID) != nil, "nothing is deleted before confirming")

        await harness.model.confirmDelete()
        #expect(try rig.store.loadDocument(id: rig.meetingID) == nil)
        #expect(rig.spool.state.withLock { $0.removedForMeetings } == ["meeting-uuid"])
        #expect(harness.deleted.withLock { $0 } == 1)
        #expect(harness.model.isDeleted)
        #expect(harness.model.phase == .missing)
    }

    @Test func aMeetingBeingRecordedCannotBeDeletedFromTheWindow() async throws {
        let harness = WindowHarness(try WindowRig(status: .recording))
        await harness.model.load()
        #expect(!harness.model.canDelete)
        harness.model.requestDelete()
        #expect(!harness.model.isConfirmingDelete)
    }
}
