import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private func ids(_ rows: [NoteRow]) -> [String] { rows.map { $0.id.key.rawValue } }

@Suite("Notes and Dictations lists")
struct NoteCollectionTests {
    private func rig() -> (NoteLibrary, ScriptedNoteSource, ScriptedNoteSource) {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 100), Fixtures.summary("meetings", "c", secondsAgo: 300),
            ])
        let dictation = ScriptedNoteSource(
            "dictation",
            items: [
                Fixtures.summary("dictation", "s/1", secondsAgo: 200, kind: .dictation),
                Fixtures.summary("dictation", "s/2", secondsAgo: 400, kind: .dictation),
            ])
        // A manual note, and the kept copy of a dictation whose recording is gone.
        let gone = Fixtures.overlay(2, Fixtures.key("dictation", "s/9"), layer: "cleaned", startedAt: Fixtures.epoch)
        var kept = gone
        kept.kind = .dictation
        let store = FakeOverlayStore(
            present: [Fixtures.manual(1, "m", secondsAgo: 250, title: "Plan")], detached: [kept])
        return (NoteLibrary(box: SourceBox([meetings, dictation]), store: store), meetings, dictation)
    }

    @Test("classification reads the plugin id and the kind only")
    func classification() {
        #expect(NoteCollection.of(key: Fixtures.key("meetings", "a")) == .notes)
        #expect(NoteCollection.of(key: Fixtures.key("notes", "x"), kind: .manual) == .notes)
        #expect(NoteCollection.of(key: Fixtures.key("dictation", "s/1")) == .dictations)
        #expect(NoteCollection.of(key: Fixtures.key("anything", "1"), kind: .dictation) == .dictations)
        #expect(NoteCollection.of(.detached(Fixtures.key("dictation", "s/1"), startedAtMs: 1)) == .dictations)
    }

    @Test("Notes lists meetings and manual notes, Dictations only dictations (live and kept copies)")
    func split() async {
        let (library, meetings, dictation) = rig()
        let notes = await library.list(matching: nil, after: nil, limit: 10, collection: .notes)
        #expect(ids(notes.rows) == ["meetings:a", "notes:m", "meetings:c"])
        #expect(notes.total == 3)
        let dictations = await library.list(matching: nil, after: nil, limit: 10, collection: .dictations)
        #expect(Set(ids(dictations.rows)) == ["dictation:s/1", "dictation:s/2", "dictation:s/9"])
        #expect(!ids(dictations.rows).contains("notes:m"))
        // The list that is not shown does not ask its sources at all.
        #expect(meetings.listCalls == 1)
        #expect(dictation.listCalls == 1)
        let all = await library.list(matching: nil, after: nil, limit: 10)
        #expect(all.rows.count == 6)
    }

    @Test("a dictation source that is down does not touch the Notes list")
    func downSourceStaysInItsList() async {
        let (library, _, dictation) = rig()
        dictation.behavior = .throwsError
        let notes = await library.list(matching: nil, after: nil, limit: 10, collection: .notes)
        #expect(notes.unavailable.isEmpty)
        let dictations = await library.list(matching: nil, after: nil, limit: 10, collection: .dictations)
        #expect(dictations.unavailable.map(\.pluginID) == ["dictation"])
    }
}
