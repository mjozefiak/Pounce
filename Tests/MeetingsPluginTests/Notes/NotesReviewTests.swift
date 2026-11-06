import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A runtime whose load cannot be cancelled (like a real model load): it returns only when the test lets it.
final class StuckLoadLLM: LLMRuntime, @unchecked Sendable {
    let contextLength = 8192
    private let open = Mutex(false)
    private let loadStarted = Mutex(false)
    private let loaded = Mutex(false)

    var isLoaded: Bool { get async { loaded.withLock { $0 } } }

    var started: Bool { loadStarted.withLock { $0 } }

    func letGo() { open.withLock { $0 = true } }

    func load(modelAt url: URL) async throws {
        loadStarted.withLock { $0 = true }
        while !open.withLock({ $0 }) {
            // Ignores cancellation on purpose.
            try? await Task.sleep(for: .milliseconds(2))
        }
        loaded.withLock { $0 = true }
    }

    func unload() async {}

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String { "" }

    func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult { .done("") }
}

@MainActor
@Suite struct NotesReviewServiceTests {
    // MARK: M1

    @Test func partialNotesNeverReplaceCompleteOnes() async throws {
        let broken = Flag()
        let rig = try NotesServiceRig(
            handler: { _, messages, _ in
                if broken.isSet, NotesFake.isMap(messages), NotesFake.lastUser(messages).contains("numer 7 ") {
                    throw NotesFake.Failure()
                }
                return .done(NotesFake.answer(messages))
            }, configure: { $0.chunkTokens = 150 })
        await rig.start()
        let id = try rig.addMeeting(NotesFixtures.filler(count: 20))
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
        let complete = try #require(try rig.document(id).notesMarkdown)

        broken.set()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        // The text stays; the status says the new run did not work out.
        #expect(try rig.record(id).status == .failed)
        #expect(try rig.document(id).notesMarkdown == complete)

        // Without earlier complete notes a partial result is stored as before.
        let other = try rig.addMeeting(NotesFixtures.filler(count: 20))
        rig.service.regenerate(other)
        #expect(await rig.settle())
        #expect(try rig.record(other).status == .partial)
        #expect(try rig.record(other).hasMarkdown)
    }

    // MARK: M2

    @Test func aRenameBeforeTheFirstNotesExistMarksThemStaleAndTheyAreStoredStale() throws {
        let rig = try NotesServiceRig()
        let id = try rig.addMeeting()
        let previous = try #require(try rig.store.beginNotes(id))
        #expect(previous == NotesStatus.none)
        try rig.store.renameSpeaker(rig.speakerID(of: id, named: "Anna"), label: "Anna Nowak")
        #expect(try rig.record(id).status == .stale)

        let outcome = try rig.store.finishNotes(
            id, markdown: "## Notes", status: .ok, promptVersion: "1", model: "m", droppedCount: 0,
            generatedAt: rig.fixedNow)
        #expect(outcome == .storedStale)
        let record = try rig.record(id)
        #expect(record.status == .stale)
        #expect(record.hasMarkdown)
        // Notes that were never started cannot be finished.
        let gone = try rig.addMeeting()
        #expect(
            try rig.store.finishNotes(
                gone, markdown: "x", status: .ok, promptVersion: "1", model: "m", droppedCount: 0,
                generatedAt: rig.fixedNow) == .discarded)
        #expect(try rig.record(gone).status == .none)
    }

    @Test func markingMyselfDuringTheFirstGenerationMarksItStaleToo() throws {
        let rig = try NotesServiceRig()
        let id = try rig.addMeeting()
        _ = try rig.store.beginNotes(id)
        let marked = try rig.store.markSelf(speakerID: rig.speakerID(of: id, named: "Marek"))
        try #require(marked)
        #expect(try rig.record(id).status == .stale)
        // A meeting with no notes and no job is not touched by a rename.
        let quiet = try rig.addMeeting()
        try rig.store.renameSpeaker(rig.speakerID(of: quiet, named: "Anna"), label: "Anna Nowak")
        #expect(try rig.record(quiet).status == .none)
    }

    @Test func aRenameDuringTheFirstGenerationEndsInNotesWithTheNewName() async throws {
        let hold = Flag()
        let reached = Flag()
        let rig = try NotesServiceRig { _, messages, _ in
            if hold.isSet {
                reached.set()
                while hold.isSet { try await Task.sleep(for: .milliseconds(2)) }
            }
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        hold.set()
        let id = try rig.addMeeting()
        rig.service.meetingBecameReady(id)
        #expect(await waitFor { reached.isSet })
        #expect(try rig.record(id).status == .running)
        try rig.store.renameSpeaker(rig.speakerID(of: id, named: "Marek"), label: "Marek Kowalski")
        #expect(try rig.record(id).status == .stale)
        hold.clear()
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
        #expect(try #require(try rig.document(id).notesMarkdown).contains("Marek Kowalski"))
    }

    // MARK: M3

    @Test func aRegenerateRequestWhileTheJobRunsIsNotLostButRunsRightAfter() async throws {
        let hold = Flag()
        let reached = Flag()
        let rig = try NotesServiceRig { _, messages, _ in
            if hold.isSet {
                reached.set()
                while hold.isSet { try await Task.sleep(for: .milliseconds(2)) }
            }
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        hold.set()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await waitFor { reached.isSet })
        rig.service.regenerate(id)
        rig.service.regenerate(id)
        hold.clear()
        #expect(await rig.settle())
        // Two runs (the second request counts once), two maps and two reduces.
        #expect(rig.llm.calls.filter { NotesFake.isMap($0.messages) }.count == 2)
        #expect(try rig.record(id).status == .ok)
    }

    // MARK: M5

    @Test func onlyMeetingsThatFinishedWhileNotesWereOnAndTheModelMissingShowTheBadge() async throws {
        let rig = try NotesServiceRig()
        rig.file.update { $0 = nil }
        let old = try rig.addMeeting()
        await rig.start()
        let fresh = try rig.addMeeting()
        rig.library.meetingReady(fresh)
        #expect(await rig.settle())
        let snapshot = rig.service.board.snapshot
        #expect(snapshot.needsModel)
        #expect(snapshot.needsModel(for: fresh))
        #expect(!snapshot.needsModel(for: old))

        let source = MeetingsLibrarySource(
            store: { rig.library.store },
            actions: MeetingsLibraryActions(library: rig.library, pasteboard: InertPasteboard()),
            notes: rig.service.board, openNotesModel: {})
        let rows = try await source.search(NormalizedQuery(raw: "", normalized: ""), filter: nil, limit: 10)
        let badges = Dictionary(
            uniqueKeysWithValues: rows.map { (MeetingLibraryPresentation.meetingID($0.itemKey), $0.badge) })
        #expect(badges[fresh] == "Notes model needed")
        #expect(badges[old] == .some(nil))

        // The model arrives: no catch-up, no badge, and "Regenerate" still works for any meeting.
        rig.file.update { $0 = URL(filePath: "/models/llm/notes-test.gguf") }
        await rig.service.refreshAvailability()
        #expect(await rig.settle())
        #expect(rig.llm.calls.isEmpty)
        #expect(!rig.service.board.snapshot.needsModel(for: fresh))
        #expect(try rig.record(fresh).status == .none)
        #expect(try rig.record(old).status == .none)
        rig.service.regenerate(old)
        #expect(await rig.settle())
        #expect(try rig.record(old).status == .ok)
    }

    @Test func aMeetingThatFinishedWhileNotesWereOffNeverShowsTheBadge() async throws {
        let rig = try NotesServiceRig(settings: [:])
        rig.file.update { $0 = nil }
        await rig.start()
        let id = try rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        #expect(!rig.service.board.snapshot.needsModel(for: id))
        #expect(!rig.service.board.snapshot.needsModel)
    }

    // MARK: M6

    @Test func closingOrErasingTheLibraryStopsTheRunningJob() async throws {
        for erase in [false, true] {
            let started = Flag()
            let rig = try NotesServiceRig { _, _, _ in
                started.set()
                try await Task.sleep(for: .seconds(3600))
                return .done("NONE")
            }
            await rig.start()
            let id = try rig.addMeeting()
            let queued = try rig.addMeeting()
            rig.service.regenerate(id)
            rig.service.regenerate(queued)
            #expect(await waitFor { started.isSet })
            if erase {
                try rig.library.erase()
            } else {
                rig.library.close()
            }
            #expect(await rig.settle())
            // Only the running job ever called the model; the queued one was dropped.
            #expect(rig.llm.calls.count == 1)
            #expect(await rig.lease.activeLeases == 0)
            #expect(rig.service.board.snapshot.phases.isEmpty)
        }
    }

    @Test func aMeetingThatBecomesReadyAfterTheShutdownStaysWithoutNotes() async throws {
        let rig = try NotesServiceRig()
        await rig.start()
        let id = try rig.addMeeting()
        await rig.service.shutDown()
        rig.library.meetingReady(id)
        #expect(!rig.service.isBusy)
        #expect(rig.llm.calls.isEmpty)
        #expect(try rig.record(id).status == .none)
        // Switched on again: nothing is caught up by itself; the user can regenerate.
        await rig.service.start()
        #expect(!rig.service.isBusy)
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
    }

    // MARK: M7

    @Test func shuttingDownDoesNotWaitForAModelThatCannotBeInterrupted() async throws {
        let stuck = StuckLoadLLM()
        let rig = try NotesServiceRig(runtime: stuck, shutdownLimit: .milliseconds(100))
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await waitFor { stuck.started })
        let clock = ContinuousClock()
        let elapsed = await clock.measure { await rig.service.shutDown() }
        #expect(elapsed < .seconds(3))
        #expect(!rig.service.isBusy)

        // The plugin can be switched on again at once, while the old load is still stuck.
        await rig.service.start()
        #expect(!rig.service.isBusy)
        stuck.letGo()
        // The old job finds the world moved on: it does not touch the new state.
        for _ in 0..<50 { await Task.yield() }
        #expect(!rig.service.isBusy)
    }
}

@MainActor
@Suite struct NotesReviewReadyHookTests {
    private let words: [Int: String] = [
        11: "Pierwsza wypowiedź", 12: "Druga wypowiedź", 21: "Dzisiaj omawiamy plan wdrożenia nowej wersji",
        22: "Dzisiaj omawiamy plan wdrożenia nowej wersji",
    ]

    @Test func aMeetingResumedInTheBackgroundTellsTheNotesServiceItIsReady() async throws {
        let rig = try RecoveryRig(texts: words)
        let mic = TrackScript.build([(1, 11, 3), (4, 12, 3)], tail: 1)
        let meeting = try rig.seed(.processing, mic: mic, stored: [(.mic, 16_000..<64_000, words[11]!)])
        let library = rig.library(resumer: rig.resumerFactory(mic: mic))
        let told = Shared<[Int64]>([])
        library.onMeetingReady = { id in told.update { $0.append(id) } }
        library.open()
        #expect(await waitFor { told.get() == [meeting.id] })
        #expect(try #require(library.store).status(of: meeting.id) == .ready)
    }

    @Test func aMeetingFinishedByHandTellsTheNotesServiceOnlyWhenItBecomesReady() async throws {
        let rig = try RecoveryRig(texts: words)
        let mic = TrackScript.build([(1, 11, 3), (4, 12, 3)], tail: 1)
        let meeting = try rig.seed(.incomplete, mic: mic, stored: [(.mic, 16_000..<64_000, words[11]!)])
        let library = rig.library(resumer: rig.resumerFactory(mic: mic))
        let told = Shared<[Int64]>([])
        library.onMeetingReady = { id in told.update { $0.append(id) } }
        library.open()
        let handle = try #require(library.finish(meetingID: meeting.id))
        #expect(await handle.outcome == .ready)
        #expect(await waitFor { told.get() == [meeting.id] })
        // Another finish of the same meeting does nothing and tells nothing.
        #expect(library.finish(meetingID: meeting.id) == nil)
        #expect(told.get() == [meeting.id])
    }
}
