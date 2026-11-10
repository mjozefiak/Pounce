import Testing

@testable import LintelCore

@Suite struct MarkdownTextTests {
    // MARK: cleaned (moved from the Meetings export, behaviour unchanged)

    @Test func cleanedTurnsLineBreaksAndControlsIntoOneSpace() {
        #expect(MarkdownText.cleaned("a\nb\r\nc\u{2028}d\u{85}e", keepNewlines: false) == "a b c d e")
        #expect(MarkdownText.cleaned("a\u{0}\u{7}b\u{9B}c", keepNewlines: false) == "a b c")
        #expect(MarkdownText.cleaned("a\n\n\nb", keepNewlines: false) == "a b")
        #expect(MarkdownText.cleaned("a\tb", keepNewlines: false) == "a b")
    }

    @Test func cleanedKeepsLineBreaksOnRequest() {
        #expect(MarkdownText.cleaned("a\r\nb\u{2029}c", keepNewlines: true) == "a\nb\nc")
    }

    @Test func cleanedRemovesInvisibleAndBidiCharactersButKeepsJoiners() {
        #expect(MarkdownText.cleaned("\u{202E}x\u{2066}", keepNewlines: false) == "x")
        #expect(MarkdownText.cleaned("\u{3164}\u{FFA0}\u{2800}", keepNewlines: false) == "")
        #expect(MarkdownText.cleaned("a\u{200B}b", keepNewlines: false) == "ab")
        #expect(MarkdownText.cleaned("a\u{200C}b\u{200D}c", keepNewlines: false) == "a\u{200C}b\u{200D}c")
    }

    // MARK: strippingBidiAndControls

    @Test func strippingKeepsTabsNewlinesAndSpacesUntouched() {
        let text = "# Title\n\n- a\n\t- b\n  two  spaces\n"
        #expect(MarkdownText.strippingBidiAndControls(text) == text)
    }

    @Test func strippingNormalisesLineBreaksToNewline() {
        #expect(MarkdownText.strippingBidiAndControls("a\r\nb\rc\u{2028}d\u{2029}e\u{85}f") == "a\nb\nc\nd\ne\nf")
    }

    @Test func strippingRemovesBidiControls() {
        #expect(MarkdownText.strippingBidiAndControls("a\u{202E}b\u{202C}c\u{2066}d\u{2069}e\u{200F}f") == "abcdef")
    }

    @Test func strippingRemovesZeroWidthAndInvisibleCharacters() {
        #expect(MarkdownText.strippingBidiAndControls("a\u{200B}b\u{2060}c\u{FEFF}d\u{00AD}e") == "abcde")
        #expect(MarkdownText.strippingBidiAndControls("x\u{3164}\u{2800}y") == "xy")
        #expect(MarkdownText.strippingBidiAndControls("tag\u{E0041}") == "tag")
    }

    @Test func strippingKeepsJoinersEmojiAndPolishLetters() {
        let text = "ZA\u{017C}\u{00F3}\u{0142}\u{0107} g\u{0119}\u{015B}l\u{0105} \u{1F468}\u{200D}\u{1F469}"
        #expect(MarkdownText.strippingBidiAndControls(text) == text)
    }

    @Test func strippingRemovesControlCharactersEverywhereIncludingCodeBlocks() {
        let text = "```\nlet a\u{0}= 1\u{202E}\n\tindented\n```"
        #expect(MarkdownText.strippingBidiAndControls(text) == "```\nlet a= 1\n\tindented\n```")
        #expect(MarkdownText.strippingBidiAndControls("a\u{7}b\u{9B}c\u{7F}d") == "abcd")
    }

    @Test func strippingDoesNotTouchMarkdownSyntax() {
        let text = "**bold** [x](http://example.invalid) <b>"
        #expect(MarkdownText.strippingBidiAndControls(text) == text)
    }

    @Test func strippingIsIdempotent() {
        let once = MarkdownText.strippingBidiAndControls("a\u{202E}\r\nb\u{200B}\tc\u{0}")
        #expect(MarkdownText.strippingBidiAndControls(once) == once)
    }
}
