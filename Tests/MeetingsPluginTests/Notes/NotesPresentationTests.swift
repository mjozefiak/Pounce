import Foundation
import GRDB
import LintelKit
import Testing

@testable import MeetingsPlugin

@MainActor
private func windowModel(
    _ rig: WindowRig, board: NotesBoard? = nil, regenerate: (@MainActor (Int64) -> Void)? = nil,
    openNotesModel: @escaping @MainActor () -> Void = {}
) -> MeetingWindowModel {
    MeetingWindowModel(
        meetingID: rig.meetingID, store: rig.store, spool: rig.spool, pasteboard: RecordingPasteboard(),
        saver: FakeFileSaver(), regenerate: regenerate, labels: .english, timeZone: ExportFixtures.utc, notes: board,
        openNotesModel: openNotesModel, pollInterval: .milliseconds(1), sleep: { _ in await Task.yield() })
}

@MainActor
@Suite struct NotesWindowTests {
    @Test func theWindowShowsWhatEachNotesStatusMeans() async throws {
        func banners(_ rig: WindowRig, board: NotesBoard? = nil) async -> [MeetingWindowModel.Banner] {
            let model = windowModel(rig, board: board)
            await model.load()
            return model.banners
        }
        let failed = try WindowRig()
        try failed.store.write { $0.setColumn(failed.meetingID, "notes_status = 'failed'") }
        #expect(await banners(failed) == [.notesFailed])

        let partial = try WindowRig(notes: "n")
        try partial.store.write { $0.setColumn(partial.meetingID, "notes_status = 'partial'") }
        #expect(await banners(partial) == [.notesPartial])

        let dropped = try WindowRig(notes: "n")
        try dropped.store.write { $0.setColumn(dropped.meetingID, "notes_dropped_count = 3") }
        #expect(await banners(dropped) == [.notesDropped(3)])

        let running = try WindowRig()
        try running.store.write { $0.setColumn(running.meetingID, "notes_status = 'running'") }
        #expect(await banners(running) == [.notesWriting(nil)])

        let board = NotesBoard()
        board.update { $0.phases[running.meetingID] = .waitingForModel }
        #expect(await banners(running, board: board) == [.notesWriting(.waitingForModel)])

        let needs = try WindowRig()
        let wanting = NotesBoard()
        wanting.update {
            $0.enabled = true
            $0.modelMissing = true
            $0.awaitingModel = [needs.meetingID]
        }
        #expect(await banners(needs, board: wanting) == [.notesNeedsModel])
        // Notes that are off do not nag.
        #expect(await banners(try WindowRig(), board: NotesBoard()) == [])
        // A meeting that is not ready does not offer notes.
        #expect(await banners(try WindowRig(status: .incomplete), board: wanting) == [.incomplete(canFinish: true)])
    }

    @Test func theDownloadButtonOpensTheNotesModel() async throws {
        let opened = Box(0)
        let model = windowModel(try WindowRig(), openNotesModel: { opened.withLock { $0 += 1 } })
        model.downloadNotesModel()
        #expect(opened.withLock { $0 } == 1)
    }

    @Test func regenerateIsOfferedForStaleAndFailedNotesButNotWhileWriting() async throws {
        let calls = Box<[Int64]>([])
        let rig = try WindowRig(notes: "n")
        try rig.store.renameSpeaker(rig.anna, label: "Anna")
        let board = NotesBoard()
        let model = windowModel(rig, board: board, regenerate: { id in calls.withLock { $0.append(id) } })
        await model.load()
        #expect(model.canRegenerate)
        board.update { $0.phases[rig.meetingID] = .queued }
        #expect(!model.canRegenerate)
        model.regenerateNotes()
        #expect(calls.withLock { $0 }.isEmpty)
        board.update { $0.phases = [:] }
        model.regenerateNotes()
        #expect(calls.withLock { $0 } == [rig.meetingID])
        model.stopFollowing()
    }

    @Test func theWindowFollowsAJobUntilItEnds() async throws {
        let rig = try WindowRig()
        let board = NotesBoard()
        board.update { $0.phases[rig.meetingID] = .queued }
        try rig.store.write { $0.setColumn(rig.meetingID, "notes_status = 'running'") }
        let model = windowModel(rig, board: board)
        await model.load()
        #expect(model.banners == [.notesWriting(.queued)])
        model.follow()

        // The job finishes: the store and the board change; the window picks both up by itself.
        try rig.store.setNotes(rig.meetingID, markdown: "Notes", status: .ok)
        board.update { $0.phases = [:] }
        #expect(await waitFor { model.document?.notesStatus == .ok })
        #expect(model.banners.isEmpty)
        model.stopFollowing()
    }
}

extension Database {
    fileprivate func setColumn(_ id: Int64, _ assignment: String) {
        try? execute(sql: "UPDATE meeting SET \(assignment) WHERE id = ?", arguments: [id])
    }
}

@Suite struct NotesPresentationTests {
    @Test func theLibraryTellsWhatTheNotesJobDoes() {
        let entry = MeetingLibraryEntry(
            id: 1, startedAt: Date(), durationMs: 1000, title: nil, sourceBundleID: nil, status: .ready,
            notesStatus: .running, hasNotes: false)
        #expect(MeetingLibraryPresentation.badge(entry, phase: .waitingForModel) == "Waiting for the model")
        #expect(MeetingLibraryPresentation.badge(entry, phase: .queued) == "Notes queued")
        #expect(MeetingLibraryPresentation.badge(entry, phase: .reducing) == "Finishing notes")
        #expect(MeetingLibraryPresentation.badge(entry, phase: .mapping(done: 2, total: 8)) == "Writing notes 3 of 8")
        #expect(MeetingLibraryPresentation.badge(entry, phase: .mapping(done: 8, total: 8)) == "Writing notes 8 of 8")
        #expect(MeetingLibraryPresentation.badge(entry, phase: .mapping(done: 0, total: 0)) == "Writing notes")
        #expect(MeetingLibraryPresentation.badge(entry) == "Writing notes")
        // An unfinished meeting shows its own state, not the notes'.
        var unfinished = entry
        unfinished.status = .processing
        #expect(MeetingLibraryPresentation.badge(unfinished, phase: .queued) == "Processing")
        // The model badge is only for a ready meeting with no notes.
        var none = entry
        none.notesStatus = .none
        #expect(MeetingLibraryPresentation.badge(none, needsNotesModel: true) == "Notes model needed")
        none.notesStatus = .ok
        #expect(MeetingLibraryPresentation.badge(none, needsNotesModel: true) == "Notes")
    }

    @Test func thePreviewExplainsPartialFailedAndDroppedNotes() {
        func document(_ status: NotesStatus, dropped: Int = 0) -> MeetingDocument {
            MeetingDocument(
                id: 1, uuid: "u", startedAt: Date(), durationMs: 1000, title: nil, status: .ready,
                speakerMode: .diarized, audioState: .deleted, notesMarkdown: "## Summary\n\nText", notesStatus: status,
                notesDroppedCount: dropped, speakers: [], segments: [])
        }
        func notice(_ document: MeetingDocument) -> String? {
            MeetingPreviewBuilder.build(document, labels: .english, locale: Locale(identifier: "en_US")).notice
        }
        #expect(notice(document(.ok)) == nil)
        #expect(notice(document(.stale)) == MarkdownExporter.Labels.english.staleNotes)
        #expect(notice(document(.partial)) == NotesMessages.partialNotice)
        #expect(notice(document(.failed)) == NotesMessages.failedNotice)
        #expect(notice(document(.ok, dropped: 2)) == NotesMessages.dropped(2))
        #expect(
            notice(document(.partial, dropped: 1)) == NotesMessages.partialNotice + "\n" + NotesMessages.dropped(1))
    }
}

@Suite struct NotesStringCatalogTests {
    private struct Catalog: Decodable {
        struct Unit: Decodable {
            var state: String
            var value: String
        }
        struct Plural: Decodable { var stringUnit: Unit }
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Variations: Decodable { var plural: [String: Plural]? }
                var stringUnit: Unit?
                var variations: Variations?
            }
            var localizations: [String: Localization]?
        }
        var strings: [String: Entry]
    }

    private func load() throws -> Catalog {
        let root = TestPaths.repoRoot
        return try JSONDecoder().decode(
            Catalog.self, from: Data(contentsOf: root.appending(path: "Resources/Localizable.xcstrings")))
    }

    @Test func everyNotesStringHasEnglishAndPolish() throws {
        let catalog = try load()
        let keys = [
            "Notes model needed", "Notes queued", "Waiting for the model", "Writing notes %lld of %lld",
            "Finishing notes", "Download Notes Model", "Writing notes is not available.", "Writing notes…",
            "These notes miss parts of the recording that could not be read.",
            "Writing the notes failed. The notes below are from an earlier run.",
            "The notes could not be written. The transcript is unchanged; try Regenerate Notes.",
            "The notes miss some parts of the recording that could not be read. Regenerate Notes to try again.",
            "Notes are on, but their model is not downloaded.",
            "The notes model is in use right now. Try again when the notes are written.",
            "Write notes after each meeting", "The model you chose does not fit this Mac, so %@ is used.",
            "Try it on an example", "Example", "Notes for a made-up meeting. Nothing was saved.",
            "The example did not work. Try again in a moment.", "Download the model first.",
        ]
        for key in keys {
            let entry = try #require(catalog.strings[key], "\(key) is missing")
            for language in ["en", "pl"] {
                let unit = try #require(entry.localizations?[language]?.stringUnit, "\(key) lacks \(language)")
                #expect(unit.state == "translated" && !unit.value.isEmpty, "\(key) \(language)")
            }
        }
        #expect(catalog.strings["Notes are generated in a later version of Lintel."] == nil)
        #expect(
            catalog.strings["Try it on an example"]?.localizations?["pl"]?.stringUnit?.value
                == "Wypróbuj na przykładzie")
        #expect(catalog.strings["Waiting for the model"]?.localizations?["pl"]?.stringUnit?.value == "Czeka na model")
        #expect(
            catalog.strings["Download Notes Model"]?.localizations?["pl"]?.stringUnit?.value == "Pobierz model notatek")
    }

    @Test func theDroppedNoteHasEveryPolishPluralForm() throws {
        let entry = try #require(try load().strings["%lld points not backed by the recording were left out"])
        let polish = try #require(entry.localizations?["pl"]?.variations?.plural)
        #expect(Set(polish.keys) == ["one", "few", "many", "other"])
        #expect(polish["one"]?.stringUnit.value == "%lld punkt bez pokrycia w nagraniu pominięto")
        #expect(polish["few"]?.stringUnit.value == "%lld punkty bez pokrycia w nagraniu pominięto")
        #expect(polish["many"]?.stringUnit.value == "%lld punktów bez pokrycia w nagraniu pominięto")
        let english = try #require(entry.localizations?["en"]?.variations?.plural)
        #expect(Set(english.keys) == ["one", "other"])
    }
}
