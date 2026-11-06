import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct NotesServiceFlowTests {
    @Test func aMeetingThatBecomesReadyGetsItsNotes() async throws {
        let rig = try NotesServiceRig()
        await rig.start()
        let id = try rig.addMeeting()
        let before = try rig.document(id)
        rig.library.meetingReady(id)
        #expect(await rig.settle())

        let record = try rig.record(id)
        #expect(record.status == .ok)
        #expect(record.model == LLMModelCatalog.defaultModel.id)
        #expect(record.promptVersion == String(NotesPrompt.version))
        #expect(record.droppedCount == 0)
        #expect(record.generatedAt == rig.fixedNow)
        let after = try rig.document(id)
        let notes = try #require(after.notesMarkdown)
        #expect(notes.contains("Zatwierdzamy ten budżet bez zmian"))
        // The transcript is exactly what it was.
        #expect(after.segments == before.segments)
        #expect(after.speakers == before.speakers)
        // Nothing is left of the job: no phase, the model given back.
        #expect(rig.service.board.snapshot.phases.isEmpty)
        #expect(await rig.lease.activeLeases == 0)
        #expect(rig.llm.calls.allSatisfy { $0.messages.first?.role == "system" })
    }

    @Test func theStatusRunsWhileTheModelWorks() async throws {
        let gate = Flag()
        let rig = try NotesServiceRig { _, messages, _ in
            while !gate.isSet { try await Task.sleep(for: .milliseconds(2)) }
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.meetingBecameReady(id)
        #expect(await waitFor { (try? rig.store.notesStatus(of: id)) == .running })
        #expect(await waitFor { rig.service.board.phase(of: id) == .mapping(done: 0, total: 1) })
        let entry = try #require(try rig.store.libraryEntries(matching: nil, filter: .all, limit: 5).first)
        #expect(entry.notesStatus == .running)
        #expect(
            MeetingLibraryPresentation.badge(entry, phase: .mapping(done: 0, total: 1)) == "Writing notes 1 of 1")
        gate.set()
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
    }

    @Test func notesThatAreOffRunNothing() async throws {
        let rig = try NotesServiceRig(settings: [:])
        await rig.start()
        let id = try rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())
        #expect(rig.llm.calls.isEmpty)
        #expect(try rig.record(id).status == .none)
        #expect(try rig.document(id).notesMarkdown == nil)
        #expect(!rig.service.board.snapshot.enabled)
        // Nothing wrote the switch either.
        #expect(rig.harness.settings.value(forKey: "plugins.meetings.notesEnabled") == nil)
    }

    @Test func aRegenerateRequestWorksEvenWhenAutomaticNotesAreOff() async throws {
        let rig = try NotesServiceRig(settings: [:])
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
    }

    @Test func aMeetingThatIsNotReadyGetsNoNotes() async throws {
        let rig = try NotesServiceRig()
        await rig.start()
        let id = try rig.addMeeting(status: .incomplete)
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(rig.llm.calls.isEmpty)
        #expect(try rig.record(id).status == .none)
    }

    @Test func aMeetingWithoutTextGetsNoNotes() async throws {
        let rig = try NotesServiceRig()
        await rig.start()
        let id = try rig.addMeeting([])
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(rig.llm.calls.isEmpty)
        #expect(try rig.record(id).status == .none)
    }

    @Test func oneJobRunsAtATimeAndEveryMeetingIsServed() async throws {
        let counts = Shared((active: 0, peak: 0))
        let rig = try NotesServiceRig { _, messages, _ in
            counts.update {
                $0.active += 1
                $0.peak = max($0.peak, $0.active)
            }
            defer { counts.update { $0.active -= 1 } }
            try await Task.sleep(for: .milliseconds(3))
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        let ids = try (0..<3).map { _ in try rig.addMeeting() }
        for id in ids { rig.service.meetingBecameReady(id) }
        // The same meeting twice is one job.
        rig.service.meetingBecameReady(ids[0])
        #expect(await rig.settle())
        for id in ids { #expect(try rig.record(id).status == .ok) }
        #expect(counts.get().peak == 1)
    }

    @Test func theLibraryTellsTheServiceWhenAControllerRecordingIsReady() async throws {
        let rig = try ControllerRig()
        let told = Shared<[Int64]>([])
        rig.library.onMeetingReady = { id in told.update { $0.append(id) } }
        rig.behaviour.outcome = MeetingSessionOutcome(result: .ready, meetingID: 7)
        await rig.startRecording()
        rig.controller.stop()
        await eventually { rig.hud.last == .saved }
        #expect(told.get() == [7])

        let other = try ControllerRig()
        let none = Shared<[Int64]>([])
        other.library.onMeetingReady = { id in none.update { $0.append(id) } }
        other.behaviour.outcome = MeetingSessionOutcome(result: .incomplete, meetingID: 8)
        await other.startRecording()
        other.controller.stop()
        await eventually { other.hud.last == .savedIncomplete }
        #expect(none.get().isEmpty)
    }
}

@MainActor
@Suite struct NotesServiceFailureTests {
    @Test func aMissingModelLeavesTheNotesAloneAndOffersTheDownload() async throws {
        let rig = try NotesServiceRig()
        rig.file.update { $0 = nil }
        await rig.start()
        #expect(rig.service.board.snapshot.needsModel)
        let id = try rig.addMeeting()
        rig.library.meetingReady(id)
        #expect(await rig.settle())

        #expect(rig.llm.calls.isEmpty)
        #expect(try rig.record(id).status == .none)
        #expect(rig.modelsOpened.get().isEmpty)
        let entry = try #require(try rig.store.libraryEntries(matching: nil, filter: .all, limit: 5).first)
        #expect(MeetingLibraryPresentation.badge(entry, needsNotesModel: true) == "Notes model needed")
        #expect(MeetingLibraryPresentation.badge(entry) == nil)

        // The list offers the download on that row, and only there.
        let source = MeetingsLibrarySource(
            store: { rig.library.store },
            actions: MeetingsLibraryActions(library: rig.library, pasteboard: InertPasteboard()),
            notes: rig.service.board, openNotesModel: { rig.modelsOpened.update { $0.append(nil) } })
        let rows = try await source.search(NormalizedQuery(raw: "", normalized: ""), filter: nil, limit: 10)
        let row = try #require(rows.first)
        #expect(row.badge == "Notes model needed")
        #expect(source.actions(for: row).contains { $0.id == "meetings.library.notesModel" })
        let ready = Candidate(itemKey: row.itemKey, title: row.title, icon: row.icon, match: row.match, badge: "Notes")
        #expect(!source.actions(for: ready).contains { $0.id == "meetings.library.notesModel" })

        // An explicit request opens the Models pane on the notes model, and the model arriving makes the next one
        // work.
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(rig.modelsOpened.get() == [rig.settings.builtInLLMModel.id])
        rig.file.update { $0 = URL(filePath: "/models/llm/notes-test.gguf") }
        await rig.service.refreshAvailability()
        #expect(!rig.service.board.snapshot.needsModel)
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
    }

    @Test func aFailingModelMarksTheNotesFailedAndKeepsTheTranscript() async throws {
        let rig = try NotesServiceRig { _, _, _ in throw NotesFake.Failure() }
        await rig.start()
        let id = try rig.addMeeting()
        let before = try rig.document(id)
        rig.library.meetingReady(id)
        #expect(await rig.settle())

        let record = try rig.record(id)
        #expect(record.status == .failed)
        #expect(!record.hasMarkdown)
        #expect(record.generatedAt == nil)
        let after = try rig.document(id)
        #expect(after.segments == before.segments)
        #expect(after.status == .ready)
        #expect(await rig.lease.activeLeases == 0)
        #expect(rig.service.board.snapshot.phases.isEmpty)
        let entry = try #require(try rig.store.libraryEntries(matching: nil, filter: .needsAttention, limit: 5).first)
        #expect(MeetingLibraryPresentation.badge(entry) == "Notes failed")
    }

    @Test func aModelThatCannotBeLoadedMarksTheNotesFailed() async throws {
        let rig = try NotesServiceRig()
        rig.llm.failLoading()
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.meetingBecameReady(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .failed)
        #expect(rig.llm.calls.isEmpty)
    }

    @Test func aFailedRegenerationKeepsTheEarlierNotes() async throws {
        let fail = Flag()
        let rig = try NotesServiceRig { _, messages, _ in
            if fail.isSet { throw NotesFake.Failure() }
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        let earlier = try #require(try rig.document(id).notesMarkdown)
        fail.set()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .failed)
        #expect(try rig.document(id).notesMarkdown == earlier)
    }

    @Test func aChunkTheModelCannotReadLeavesPartialNotes() async throws {
        let rig = try NotesServiceRig(
            handler: { _, messages, _ in
                if NotesFake.isMap(messages), NotesFake.lastUser(messages).contains("numer 7 ") {
                    throw NotesFake.Failure()
                }
                return .done(NotesFake.answer(messages))
            }, configure: { $0.chunkTokens = 150 })
        await rig.start()
        let id = try rig.addMeeting(NotesFixtures.filler(count: 20))
        rig.service.regenerate(id)
        #expect(await rig.settle())
        let record = try rig.record(id)
        #expect(record.status == .partial)
        #expect(record.hasMarkdown)
        #expect(record.generatedAt == rig.fixedNow)
        let entry = try #require(try rig.store.libraryEntries(matching: nil, filter: .all, limit: 5).first)
        #expect(MeetingLibraryPresentation.badge(entry) == "Partial notes")
    }

    @Test func pointsWithoutCoverAreCountedAndKept() async throws {
        let rig = try NotesServiceRig { _, messages, _ in
            if NotesFake.isMap(messages) {
                let real = NotesFake.mapAnswer(messages)
                return .done(
                    real + "\nTASK | 0:05 | \"Anna zapłaci fakturę we wtorek\" | Zapłacić fakturę. | Anna | wtorek")
            }
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        let record = try rig.record(id)
        #expect(record.status == .ok)
        #expect(record.droppedCount == 1)
        let notes = try #require(try rig.document(id).notesMarkdown)
        #expect(!notes.contains("faktur"))
    }
}

@MainActor
@Suite struct NotesServiceLifecycleTests {
    @Test func deactivatingCancelsTheJobAndPutsTheStatusBack() async throws {
        let started = Flag()
        let rig = try NotesServiceRig { _, _, _ in
            started.set()
            try await Task.sleep(for: .seconds(3600))
            return .done("NONE")
        }
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await waitFor { started.isSet })
        #expect(try rig.record(id).status == .running)

        await rig.service.shutDown()
        let record = try rig.record(id)
        #expect(record.status == .none)
        #expect(!record.hasMarkdown)
        #expect(record.generatedAt == nil)
        #expect(!rig.service.isBusy)
        #expect(await rig.lease.activeLeases == 0)
        #expect(rig.service.board.snapshot.phases.isEmpty)
        // A stopped service takes no more work.
        rig.service.regenerate(id)
        #expect(!rig.service.isBusy)
    }

    @Test func aCancelledRegenerationRestoresTheEarlierStatus() async throws {
        let hang = Flag()
        let started = Flag()
        let rig = try NotesServiceRig { _, messages, _ in
            if hang.isSet {
                started.set()
                try await Task.sleep(for: .seconds(3600))
            }
            return .done(NotesFake.answer(messages))
        }
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        let earlier = try #require(try rig.document(id).notesMarkdown)
        try rig.store.renameSpeaker(rig.speakerID(of: id, named: "Anna"), label: "Anna Nowak")
        #expect(try rig.record(id).status == .stale)

        hang.set()
        rig.service.regenerate(id)
        #expect(await waitFor { started.isSet })
        await rig.service.shutDown()
        let record = try rig.record(id)
        #expect(record.status == .stale)
        #expect(try rig.document(id).notesMarkdown == earlier)
    }

    @Test func renamingASpeakerMakesNotesStaleAndRegeneratingFixesThem() async throws {
        let rig = try NotesServiceRig()
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.meetingBecameReady(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)

        try rig.store.renameSpeaker(rig.speakerID(of: id, named: "Marek"), label: "Marek Kowalski")
        #expect(try rig.record(id).status == .stale)
        let stale = try #require(try rig.store.libraryEntries(matching: nil, filter: .needsAttention, limit: 5).first)
        #expect(MeetingLibraryPresentation.badge(stale) == "Notes outdated")

        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
        #expect(try #require(try rig.document(id).notesMarkdown).contains("Marek Kowalski"))
    }

    @Test func aRenameDuringARegenerationStoresTheTextStaleAndWritesItAgainWithTheNewName() async throws {
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
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())

        hold.set()
        rig.service.regenerate(id)
        #expect(await waitFor { reached.isSet })
        // A real rename marks the notes stale while the job runs; the finishing job must not hide that.
        try rig.store.renameSpeaker(rig.speakerID(of: id, named: "Marek"), label: "Marek Kowalski")
        #expect(try rig.record(id).status == .stale)
        let callsBefore = rig.llm.calls.count
        hold.clear()
        #expect(await rig.settle())
        // The job wrote its text as stale and was queued again by itself: the second run has the new name.
        #expect(rig.llm.calls.count > callsBefore + 2)
        #expect(try rig.record(id).status == .ok)
        #expect(try #require(try rig.document(id).notesMarkdown).contains("Marek Kowalski"))
    }

    @Test func aBusyModelMakesTheJobWaitAndThenItRuns() async throws {
        let rig = try NotesServiceRig()
        await rig.start()
        // Dictation (or anything else) holds a different model.
        let other = ScriptedLLM(contextLength: 4096, handler: NotesFake.standard)
        let handle = try await rig.lease.acquire(
            key: .init(modelID: "/models/other.gguf", contextLength: 4096), runtime: other,
            modelURL: URL(filePath: "/models/other.gguf"), priority: .interactive, keepWarm: { .seconds(60) })
        let id = try rig.addMeeting()
        rig.service.meetingBecameReady(id)
        #expect(await waitFor { rig.service.board.phase(of: id) == .waitingForModel })
        let entry = try #require(try rig.store.libraryEntries(matching: nil, filter: .all, limit: 5).first)
        #expect(MeetingLibraryPresentation.badge(entry, phase: .waitingForModel) == "Waiting for the model")
        #expect(try rig.record(id).status == .running)
        #expect(rig.llm.calls.isEmpty)

        await handle.release()
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .ok)
    }

    @Test func aModelThatStaysBusyForTooLongFailsTheNotes() async throws {
        let rig = try NotesServiceRig(configure: { $0.busyLimit = .milliseconds(30) })
        await rig.start()
        let other = ScriptedLLM(contextLength: 4096, handler: NotesFake.standard)
        let handle = try await rig.lease.acquire(
            key: .init(modelID: "/models/other.gguf", contextLength: 4096), runtime: other,
            modelURL: URL(filePath: "/models/other.gguf"), priority: .interactive, keepWarm: { .seconds(60) })
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).status == .failed)
        await handle.release()
    }

    @Test func notesLeftRunningByACrashBecomeFailedWhenTheLibraryOpens() async throws {
        let rig = try NotesServiceRig()
        let running = try rig.addMeeting()
        let withText = try rig.addMeeting()
        let fine = try rig.addMeeting()
        try rig.store.setNotes(withText, markdown: "Earlier notes", status: .ok)
        try rig.store.setNotes(fine, markdown: "Fine notes", status: .ok)
        try rig.store.write { db in
            try db.execute(
                sql: "UPDATE meeting SET notes_status = 'running' WHERE id IN (?, ?)", arguments: [running, withText])
        }
        rig.library.close()
        rig.library.open()

        let store = try #require(rig.library.store)
        #expect(try #require(try store.notesRecord(of: running)).status == .failed)
        let kept = try #require(try store.notesRecord(of: withText))
        #expect(kept.status == .failed)
        #expect(kept.hasMarkdown)
        #expect(try #require(try store.notesRecord(of: fine)).status == .ok)
        // Nothing was started by itself.
        #expect(rig.llm.calls.isEmpty)
        #expect(try store.failInterruptedNotes() == 0)
    }

    @Test func aStoredModelThatDoesNotFitTheMemoryFallsBackToTheDefault() async throws {
        let large = LLMModelCatalog.qwen3Large
        let small = NotesServiceRig.gibibyte * 16
        let rig = try NotesServiceRig(
            settings: [
                "plugins.meetings.notesEnabled": .bool(true), "plugins.meetings.builtInLLMModel": .string(large.id),
            ], physicalMemory: small)
        #expect(rig.settings.builtInLLMModel.id == LLMModelCatalog.defaultModel.id)
        #expect(rig.settings.builtInLLMModelWasReplaced)
        #expect(rig.settings.offeredLLMModels.map(\.id) == [LLMModelCatalog.defaultModel.id])
        await rig.start()
        let id = try rig.addMeeting()
        rig.service.regenerate(id)
        #expect(await rig.settle())
        #expect(try rig.record(id).model == LLMModelCatalog.defaultModel.id)

        // On a Mac that fits it, the stored choice applies and nothing is replaced.
        let big = try NotesServiceRig(
            settings: ["plugins.meetings.builtInLLMModel": .string(large.id)],
            physicalMemory: 64 * NotesServiceRig.gibibyte)
        #expect(big.settings.builtInLLMModel.id == large.id)
        #expect(!big.settings.builtInLLMModelWasReplaced)
        #expect(big.settings.offeredLLMModels.map(\.id) == LLMModelCatalog.all.map(\.id))
    }

    @Test func aSmallMacStillOffersTheDefaultModel() throws {
        let rig = try NotesServiceRig(physicalMemory: 4 * NotesServiceRig.gibibyte)
        #expect(rig.settings.offeredLLMModels.map(\.id) == [LLMModelCatalog.defaultModel.id])
    }
}
