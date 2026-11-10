import Foundation
import Testing

@testable import NotesPlugin

/// Applies an edit like the editor does and returns the text and the selected text after it.
private func apply(_ action: NoteFormatAction, to text: String, select: Range<Int>) -> (text: String, selected: String)?
{
    guard let edit = MarkdownFormatting.edit(action, in: text, selection: select) else { return nil }
    let units = Array(text.utf16)
    let result =
        String(decoding: units[..<edit.range.lowerBound], as: UTF16.self) + edit.replacement
        + String(decoding: units[edit.range.upperBound...], as: UTF16.self)
    let out = Array(result.utf16)
    return (result, String(decoding: out[edit.selection], as: UTF16.self))
}

@Suite("Markdown formatting")
struct MarkdownFormattingTests {
    @Test("bold wraps the selection, an empty selection gets a pair with the caret between")
    func bold() throws {
        let wrapped = try #require(apply(.bold, to: "say hello now", select: 4..<9))
        #expect(wrapped.text == "say **hello** now")
        #expect(wrapped.selected == "hello")
        let empty = try #require(apply(.bold, to: "ab", select: 1..<1))
        #expect(empty.text == "a****b")
    }

    @Test("bold again takes the markers off, whether they are inside or outside the selection")
    func unwrap() throws {
        let outside = try #require(apply(.bold, to: "say **hello** now", select: 6..<11))
        #expect(outside.text == "say hello now")
        #expect(outside.selected == "hello")
        let inside = try #require(apply(.bold, to: "say **hello** now", select: 4..<13))
        #expect(inside.text == "say hello now")
    }

    @Test("italic and strikethrough use their markers; italic does not mistake bold for italic")
    func others() throws {
        #expect(try #require(apply(.italic, to: "x y", select: 0..<1)).text == "*x* y")
        #expect(try #require(apply(.strike, to: "x y", select: 0..<1)).text == "~~x~~ y")
        #expect(try #require(apply(.italic, to: "**b**", select: 2..<3)).text == "***b***")
        #expect(try #require(apply(.italic, to: "*b*", select: 1..<2)).text == "b")
    }

    @Test("a link wraps the selection and leaves the caret in the address")
    func link() throws {
        let edit = try #require(MarkdownFormatting.edit(.link, in: "see site", selection: 4..<8))
        #expect(edit.replacement == "[site]()")
        #expect(edit.selection == 11..<11)
        #expect(try #require(MarkdownFormatting.edit(.link, in: "", selection: 0..<0)).replacement == "[]()")
    }

    @Test("a heading sets the prefix of the line, replaces another prefix and toggles off")
    func headings() throws {
        #expect(try #require(apply(.heading(2), to: "Title", select: 2..<2)).text == "## Title")
        #expect(try #require(apply(.heading(1), to: "## Title", select: 0..<0)).text == "# Title")
        #expect(try #require(apply(.heading(2), to: "## Title", select: 0..<0)).text == "Title")
        #expect(try #require(apply(.paragraph, to: "### Title", select: 0..<0)).text == "Title")
        #expect(try #require(apply(.heading(1), to: "- item", select: 0..<0)).text == "# item")
        #expect(apply(.paragraph, to: "plain", select: 0..<0) == nil)
    }

    @Test("lists, tasks and quotes apply to every selected line, skip blank ones and toggle off together")
    func linePrefixes() throws {
        let text = "one\n\ntwo\nthree"
        let on = try #require(apply(.bulletList, to: text, select: 0..<text.utf16.count))
        #expect(on.text == "- one\n\n- two\n- three")
        let off = try #require(apply(.bulletList, to: on.text, select: 0..<on.text.utf16.count))
        #expect(off.text == text)
        #expect(try #require(apply(.taskList, to: "a", select: 0..<0)).text == "- [ ] a")
        #expect(try #require(apply(.quote, to: "a\nb", select: 0..<3)).text == "> a\n> b")
        #expect(try #require(apply(.bulletList, to: "1. a", select: 0..<0)).text == "- a")
        // A selection that ends right after a line break does not touch the next line.
        #expect(try #require(apply(.quote, to: "a\nb", select: 0..<2)).text == "> a\nb")
    }

    @Test("indented list items keep their indent; an empty line gets the prefix")
    func indent() throws {
        #expect(try #require(apply(.taskList, to: "  - a", select: 0..<0)).text == "  - [ ] a")
        #expect(try #require(apply(.bulletList, to: "", select: 0..<0)).text == "- ")
    }

    @Test("an out-of-range selection is clamped")
    func clamp() {
        #expect(MarkdownFormatting.edit(.bold, in: "ab", selection: 5..<9) != nil)
    }
}
