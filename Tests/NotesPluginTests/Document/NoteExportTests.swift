import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite("Copy Markdown and Save .md")
struct NoteExportTests {
    private func content(_ key: NoteKey) throws -> NoteContent {
        try #require(NotesQAFixtures.content(for: key))
    }

    @Test("the notes export is the title and the layer's Markdown")
    func notes() throws {
        let text = NoteMarkdownExport.markdown(try content(NotesQAFixtures.meetingID), layerID: "notes")
        #expect(text.hasPrefix("# Orchard weekly sync\n\n## Summary"))
        #expect(text.contains("| T1 | Update the release checklist | Kasia | Thu |"))
        #expect(text.hasSuffix("\\[12:46\\]\n"))
    }

    @Test("the transcript export has the speaker and the time before each segment")
    func transcript() throws {
        let text = NoteMarkdownExport.markdown(try content(NotesQAFixtures.meetingID), layerID: "transcript")
        #expect(text.contains("**Kasia** (12:41): I’d move the pricing page, it isn’t ready."))
        #expect(text.contains("**You** (12:42): Agreed."))
    }

    @Test("a dictation exports the layer on screen")
    func dictation() throws {
        let content = try content(NotesQAFixtures.dictationID)
        #expect(NoteMarkdownExport.markdown(content, layerID: "original").contains("hi kasia i moved"))
        #expect(NoteMarkdownExport.markdown(content, layerID: "missing") == "")
    }

    @Test("a title cannot start Markdown of its own")
    func titleIsEscaped() {
        var summary = NoteSummary(
            id: Fixtures.key("meetings", "a"), kind: .meeting, title: "# *x* [y](z)\nnext", startedAt: Fixtures.epoch)
        let content = NoteContent(
            summary: summary, layers: [NoteLayer(id: "notes", author: .agent, markdown: "Body", version: "1")],
            speakers: [], details: [])
        let text = NoteMarkdownExport.markdown(content, layerID: "notes")
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        #expect(firstLine == "# \\# \\*x\\* \\[y\\](z) next")
        summary.title = nil
        #expect(NoteMarkdownExport.displayTitle(summary) == "Untitled note")
    }

    @Test("a speaker name and a body cannot carry bidi overrides or inject lines")
    func sanitised() {
        let key = Fixtures.key("meetings", "a")
        let summary = NoteSummary(id: key, kind: .meeting, title: "T", startedAt: Fixtures.epoch)
        let speaker = NoteSpeaker(id: "s1", name: "Eve\u{202E}\n# Injected")
        let layer = NoteLayer(
            id: NoteDocumentModel.transcriptLayerID, author: .stt, markdown: "Hello\u{202E}evil\u{200B}",
            provenance: [NoteBlockProvenance(blockIndex: 0, speakerID: "s1", startMs: 1000)], version: "1")
        let content = NoteContent(summary: summary, layers: [layer], speakers: [speaker], details: [])
        let text = NoteMarkdownExport.markdown(content, layerID: NoteDocumentModel.transcriptLayerID)
        #expect(!text.contains("\u{202E}"))
        #expect(!text.contains("\u{200B}"))
        #expect(text.contains("**Eve \\# Injected** (0:01): Helloevil"))
        #expect(!text.contains("\n# Injected"))
        let notes = NoteContent(
            summary: summary,
            layers: [NoteLayer(id: "notes", author: .agent, markdown: "A\u{202E}B\r\nC", version: "1")],
            speakers: [], details: [])
        #expect(NoteMarkdownExport.markdown(notes, layerID: "notes") == "# T\n\nAB\nC\n")
    }

    @Test("a file name has no separators, no control characters, no leading dot and a limit")
    func fileNames() {
        func name(_ title: String?) -> String {
            NoteMarkdownExport.fileName(
                NoteSummary(id: Fixtures.key("meetings", "a"), kind: .meeting, title: title, startedAt: Fixtures.epoch))
        }
        #expect(name("Orchard weekly sync") == "Orchard weekly sync.md")
        #expect(name("a/b\\c:d\ne") == "a b c d e.md")
        #expect(name("..hidden") == "hidden.md")
        #expect(name("   ") == "Untitled note.md")
        #expect(name(String(repeating: "x", count: 200)).count == 83)
    }

    @Test("copying writes plain text with the transient and concealed markers, for this Mac only")
    func clipboard() throws {
        let pasteboard = RecordingPasteboard()
        NoteClipboard.copy("# Text", to: pasteboard)
        let write = try #require(pasteboard.writes.first)
        #expect(write.options == [.currentHostOnly])
        let item = try #require(write.items.first)
        #expect(write.items.count == 1)
        #expect(item.data(for: PasteboardRepresentation.plainTextType) == Data("# Text".utf8))
        #expect(item.types.contains(PasteboardRepresentation.transientMarkerType))
        #expect(item.types.contains(PasteboardRepresentation.concealedMarkerType))
    }
}
