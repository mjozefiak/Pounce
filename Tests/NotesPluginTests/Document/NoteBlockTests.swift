import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private func layer(_ markdown: String, provenance: [NoteBlockProvenance] = []) -> NoteLayer {
    NoteLayer(id: "notes", author: .agent, markdown: markdown, provenance: provenance, version: "1")
}

@Suite("Note blocks")
struct NoteBlockTests {
    @Test("headings, paragraphs, code and quotes are told apart")
    func kinds() {
        let blocks = NoteBlocks.parse(
            layer("# One\n\n### Three\n\nText\nsecond line\n\n```\ncode\n\nmore\n```\n\n> quoted"))
        #expect(
            blocks.map(\.kind) == [
                .heading(level: 1, text: "One"), .heading(level: 3, text: "Three"), .paragraph("Text second line"),
                .code("code\n\nmore"), .quote("quoted"),
            ])
        #expect(blocks.map(\.index) == [0, 1, 2, 3, 4])
        // "#hash" without a space and seven hashes are text.
        #expect(NoteBlocks.kind(of: "#hash") == .paragraph("#hash"))
        #expect(NoteBlocks.kind(of: "####### seven") == .paragraph("####### seven"))
    }

    @Test("every top-level list item is a block; nested items, numbers and tasks are read")
    func lists() {
        let blocks = NoteBlocks.parse(layer("- First\n  - nested\n- [x] Done\n- [ ] Open\n\n3. Third"))
        #expect(blocks.count == 4)
        #expect(
            blocks[0].kind
                == .list([
                    .init(depth: 0, marker: .bullet, text: "First"), .init(depth: 1, marker: .bullet, text: "nested"),
                ]))
        #expect(blocks[1].kind == .list([.init(depth: 0, marker: .task(done: true), text: "Done")]))
        #expect(blocks[2].kind == .list([.init(depth: 0, marker: .task(done: false), text: "Open")]))
        #expect(blocks[3].kind == .list([.init(depth: 0, marker: .number(3), text: "Third")]))
    }

    @Test("a continuation line joins the item before it")
    func continuation() {
        #expect(
            NoteBlocks.kind(of: "- First\n  goes on")
                == .list([.init(depth: 0, marker: .bullet, text: "First goes on")]))
    }

    @Test("a table has its header and rows, and an escaped bar stays in its cell")
    func tables() {
        let markdown = "| # | Task | Source |\n| --- | --- | --- |\n| T1 | Ship a\\|b | \\[12:44\\] |\n| T2 | Send | |"
        guard case .table(let table) = NoteBlocks.kind(of: markdown) else {
            Issue.record("not a table")
            return
        }
        #expect(table.header == ["#", "Task", "Source"])
        #expect(table.rows == [["T1", "Ship a\\|b", "\\[12:44\\]"], ["T2", "Send", ""]])
        // Two lines that only start with a bar are not a table without the separator row.
        #expect(NoteBlocks.kind(of: "| a |\n| b |") == .paragraph("| a | | b |"))
    }

    @Test("provenance is attached to the block it names")
    func provenance() {
        let blocks = NoteBlocks.parse(
            layer(
                "## Title\n\nQuoted \\[12:41\\]\n\nSegment",
                provenance: [
                    NoteBlockProvenance(blockIndex: 1, quoteTimesMs: [761_000]),
                    NoteBlockProvenance(blockIndex: 2, speakerID: "7", startMs: 5_000, segmentRef: "x"),
                ]))
        #expect(blocks[0].quoteTimesMs.isEmpty)
        #expect(blocks[1].quoteTimesMs == [761_000])
        #expect(blocks[2].speakerID == "7")
        #expect(blocks[2].startMs == 5_000)
        #expect(blocks[2].source == "Segment")
    }

    @Test("the QA meeting notes read as the prototype draws them")
    func fixtureNotes() {
        let content = NotesQAFixtures.content(for: NotesQAFixtures.meetingID)
        let notes = content?.layers.first { $0.id == "notes" }
        let blocks = notes.map(NoteBlocks.parse) ?? []
        #expect(blocks.count == 9)
        guard case .table(let table) = blocks[6].kind else {
            Issue.record("block 6 is not the tasks table")
            return
        }
        #expect(table.rows.count == 2)
        #expect(blocks[1].quoteTimesMs == [761_000])
        let transcript = content?.layers.first { $0.id == "transcript" }.map(NoteBlocks.parse) ?? []
        #expect(transcript.count == NotesQAFixtures.segments.count)
        #expect(transcript.compactMap(\.startMs) == NotesQAFixtures.segments.map(\.start))
    }
}

@Suite("Quote chips and inline text")
struct NoteInlineTests {
    @Test("a trailing time, escaped or not, is split off and read in milliseconds")
    func quotes() {
        #expect(NoteQuote.split("Ship it \\[12:41\\]") == ("Ship it", 761_000))
        #expect(NoteQuote.split("Ship it [1:02:03]") == ("Ship it", 3_723_000))
        #expect(NoteQuote.split("Ship it [12:41] then more").timeMs == nil)
        #expect(NoteQuote.split("No time [abc]").timeMs == nil)
        #expect(NoteQuote.split("[12:41]") == ("", 761_000))
    }

    @Test("clock text has minutes and seconds, and hours past an hour")
    func clock() {
        #expect(NoteQuote.clock(milliseconds: 761_000) == "12:41")
        #expect(NoteQuote.clock(milliseconds: 5_000) == "0:05")
        #expect(NoteQuote.clock(milliseconds: 3_723_000) == "1:02:03")
        #expect(NoteQuote.clock(milliseconds: -4) == "0:00")
    }

    @Test("emphasis is kept; a link and an image are not active")
    func safeInline() {
        let attributed = NoteInline.attributed("**bold** [site](https://example.com) ![pic](https://example.com/a.png)")
        #expect(attributed.runs.allSatisfy { $0.link == nil && $0.imageURL == nil })
        #expect(attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(String(attributed.characters).contains("site"))
    }

    @Test("bidirectional controls are removed")
    func bidi() {
        let attributed = NoteInline.attributed("a\u{202E}b\u{2066}c")
        #expect(String(attributed.characters) == "abc")
    }

    @Test("a broken inline Markdown still shows its text")
    func broken() {
        #expect(String(NoteInline.attributed("**unclosed [link").characters).contains("unclosed"))
    }
}
