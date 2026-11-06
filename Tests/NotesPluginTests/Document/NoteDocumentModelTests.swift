import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite("Note document")
struct NoteDocumentModelTests {
    private func meeting(now: Date = Fixtures.epoch) -> NoteDocumentModel {
        let document = NoteDocumentModel(id: .live(NotesQAFixtures.meetingID))
        document.apply(NotesQAFixtures.content(for: NotesQAFixtures.meetingID, now: now))
        return document
    }

    @Test("a loaded meeting shows its notes first and parses them")
    func loaded() {
        let document = meeting()
        #expect(document.phase == .loaded)
        #expect(document.layerID == "notes")
        #expect(document.blocks.count == 9)
        #expect(document.speakers.map(\.name) == ["Kasia", "Marek", "You"])
    }

    @Test("switching layers re-parses, and the shown layer survives a reload")
    func layers() {
        let document = meeting()
        document.selectLayer("transcript")
        #expect(document.blocks.count == 5)
        document.apply(NotesQAFixtures.content(for: NotesQAFixtures.meetingID))
        #expect(document.layerID == "transcript")
        document.selectLayer("nothing")
        #expect(document.layerID == "transcript")
    }

    @Test("a quote chip shows the transcript at the segment that was talking")
    func jump() {
        let document = meeting()
        #expect(document.jumpToTranscript(atMs: 763_500))
        #expect(document.layerID == "transcript")
        // Segments start at 761, 762, 763, 764 and 766 s: 763.5 s is inside the third.
        #expect(document.highlightedBlock == 2)
        #expect(document.scrollRequest == NoteDocumentModel.ScrollRequest(blockIndex: 2, serial: 1))
        // The same time again is a new request, so the view scrolls again.
        document.jumpToTranscript(atMs: 763_500)
        #expect(document.scrollRequest?.serial == 2)
        // Before the first segment: the first one. After the last: the last one.
        document.jumpToTranscript(atMs: 1_000)
        #expect(document.highlightedBlock == 0)
        document.jumpToTranscript(atMs: 9_999_000)
        #expect(document.highlightedBlock == 4)
        // Leaving the transcript clears the tint.
        document.selectLayer("notes")
        #expect(document.highlightedBlock == nil)
    }

    @Test("a note without a transcript cannot jump")
    func noTranscript() {
        let document = NoteDocumentModel(id: .live(NotesQAFixtures.dictationID))
        document.apply(NotesQAFixtures.content(for: NotesQAFixtures.dictationID))
        #expect(!document.jumpToTranscript(atMs: 1_000))
        #expect(document.layerID == "cleaned")
        #expect(document.scrollRequest == nil)
    }

    @Test("a dictation switches between its cleaned and original text")
    func dictation() {
        let document = NoteDocumentModel(id: .live(NotesQAFixtures.dictationID))
        document.apply(NotesQAFixtures.content(for: NotesQAFixtures.dictationID))
        #expect(document.layers.map(\.id) == ["cleaned", "original"])
        #expect(
            document.blocks.map(\.source) == [
                "Hi Kasia, I moved the review to Thursday at 10. Could you send me the agenda beforehand?"
            ])
        document.selectLayer("original")
        #expect(document.blocks.first?.source.hasPrefix("hi kasia") == true)
    }

    @Test("speaker names come from the note's speakers")
    func speakers() {
        let document = meeting()
        document.selectLayer("transcript")
        #expect(document.blocks.map { document.speakerName(of: $0) } == ["Kasia", "You", "Marek", "Kasia", "Marek"])
    }

    @Test("gone and unavailable are different")
    func phases() {
        let document = meeting()
        document.markUnavailable()
        #expect(document.phase == .loaded)
        document.apply(nil)
        #expect(document.phase == .gone)
        #expect(document.blocks.isEmpty)
        let fresh = NoteDocumentModel(id: .live(NotesQAFixtures.meetingID))
        fresh.markUnavailable()
        #expect(fresh.phase == .unavailable)
    }
}
