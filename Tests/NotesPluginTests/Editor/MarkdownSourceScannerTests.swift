import Foundation
import Testing

@testable import NotesPlugin

private typealias Scanner = MarkdownSourceScanner
private typealias Style = MarkdownSourceScanner.Style

private func styles(_ text: String) -> [(String, Style)] {
    let units = Array(text.utf16)
    return Scanner.blocks(in: units).flatMap { block in
        Scanner.runs(in: units, block: block).map { run in
            (String(decoding: units[run.range], as: UTF16.self), run.style)
        }
    }
}

private func style(of piece: String, in text: String) -> Style? {
    styles(text).first { $0.0 == piece }?.1
}

@Suite("Markdown source scanner")
struct MarkdownSourceScannerTests {
    @Test("blocks are separated by blank lines and exclude the line break")
    func blocks() {
        let text = "# Title\n\npara one\nstill one\n\n\n- a\n- b"
        let units = Array(text.utf16)
        let found = Scanner.blocks(in: units).map { String(decoding: units[$0], as: UTF16.self) }
        #expect(found == ["# Title", "para one\nstill one", "- a\n- b"])
    }

    @Test("a fenced block stays whole, blank lines included, and is its own block")
    func fences() {
        let text = "before\n```swift\nlet a = 1\n\nlet b = 2\n```\nafter"
        let units = Array(text.utf16)
        let found = Scanner.blocks(in: units).map { String(decoding: units[$0], as: UTF16.self) }
        #expect(found == ["before", "```swift\nlet a = 1\n\nlet b = 2\n```", "after"])
        let open = "```\nnever closed\n\nstill code"
        let openUnits = Array(open.utf16)
        #expect(Scanner.blocks(in: openUnits) == [0..<openUnits.count])
    }

    @Test("an empty or blank text has no blocks")
    func empty() {
        #expect(Scanner.blocks(in: []).isEmpty)
        #expect(Scanner.blocks(in: Array("  \n\t\n\n".utf16)).isEmpty)
    }

    @Test("markers stay in the text and are marked, the text between has the style")
    func inline() {
        let text = "a **bold** and *it* and ~~gone~~ and `code` end"
        #expect(style(of: "**", in: text)?.contains(.marker) == true)
        #expect(style(of: "bold", in: text) == .bold)
        #expect(style(of: "it", in: text) == .italic)
        #expect(style(of: "gone", in: text) == .strike)
        #expect(style(of: "code", in: text) == .code)
        // Every character of the source is still there, in order.
        #expect(styles(text).map(\.0).joined() == text)
    }

    @Test("nesting unions the styles; delimiters must hug their text; escapes and intraword underscores are literal")
    func inlineEdges() {
        #expect(style(of: "both", in: "***both***") == [.bold, .italic])
        #expect(style(of: "in", in: "**out *in* out**") == [.bold, .italic])
        #expect(style(of: "** not bold **", in: "** not bold **") == [])
        #expect(styles("snake_case_name").allSatisfy { $0.1 == [] })
        #expect(styles(#"\*literal\*"#).allSatisfy { $0.1 == [] })
        #expect(style(of: "a*b", in: "`a*b`") == .code)
        #expect(styles("2 * 3 * 4").allSatisfy { $0.1 == [] })
    }

    @Test("headings, quotes, lists, tasks and tables get their prefix and line styles")
    func lines() {
        #expect(style(of: "# ", in: "# Title") == [.heading1, .marker])
        #expect(style(of: "Title", in: "# Title") == .heading1)
        #expect(style(of: "Two", in: "## Two") == .heading2)
        #expect(style(of: "Deep", in: "###### Deep") == .heading3)
        #expect(style(of: "#hashtag", in: "#hashtag") == [])
        #expect(style(of: "> ", in: "> quoted") == [.quote, .marker])
        #expect(style(of: "- ", in: "- item") == .listMarker)
        #expect(style(of: "12. ", in: "12. item") == .listMarker)
        #expect(style(of: "- [x] ", in: "- [x] done") == .listMarker)
        #expect(style(of: "| a | b |", in: "| a | b |\n| --- | --- |") == .monospaced)
        #expect(style(of: "| --- | --- |", in: "| a | b |\n| --- | --- |") == [.monospaced, .marker])
        #expect(MarkdownLinePrefix.parse(Array("- [ ] t".utf16), line: 0..<7).kind == .task(done: false))
    }

    @Test("a link is styled, never given a link attribute, and its address is a marker")
    func links() {
        let text = "see [the site](https://example.com/x) now"
        #expect(style(of: "the site", in: text) == .link)
        #expect(style(of: "](https://example.com/x)", in: text) == .marker)
        #expect(style(of: "[x]", in: "[x]") == [])
    }

    @Test("code fences are monospaced with marker fence lines and no inline styling inside")
    func codeBlock() {
        let text = "```\n**not bold**\n```"
        #expect(style(of: "**not bold**", in: text) == .monospaced)
        #expect(style(of: "```", in: text) == [.monospaced, .marker])
    }

    @Test("a stray marker or an unclosed delimiter never crashes and leaves the text unstyled")
    func hostile() {
        for text in [
            "**", "*", "`", "~~", "[", "](", "[a](", "[](x)", "\\", "```", "# ", ">", "- [", "| ", "_", "***",
            "**a", "a**", "~~a", "`a", String(repeating: "*", count: 50), String(repeating: "[", count: 200),
        ] {
            #expect(styles(text).map(\.0).joined() == text)
        }
    }

    @Test("merged runs cover the block without gaps or overlaps")
    func coverage() {
        let text = "## A *b* `c` [d](e) ~~f~~ **g _h_**"
        let units = Array(text.utf16)
        let block = 0..<units.count
        let runs = Scanner.runs(in: units, block: block)
        #expect(runs.first?.range.lowerBound == 0)
        #expect(runs.last?.range.upperBound == units.count)
        for (a, b) in zip(runs, runs.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound) }
    }
}
