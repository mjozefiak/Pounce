import Testing

@testable import LintelCore

@Suite struct MarkdownBlocksTests {
    @Test func emptyAndBlankTextHasNoBlocks() {
        #expect(MarkdownBlocks.split("").isEmpty)
        #expect(MarkdownBlocks.split("\n\n  \n\t\n").isEmpty)
    }

    @Test func paragraphsAreSeparatedByBlankLinesAndKeepSoftBreaks() {
        #expect(MarkdownBlocks.split("One\ncontinues.\n\n\n\nTwo.") == ["One\ncontinues.", "Two."])
    }

    @Test func tablesAndFencesStayWholeAndListItemsSplit() {
        let md = "# Title\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n- one\n  more\n- two\n\n```\na\n\nb\n```\n\nEnd"
        #expect(
            MarkdownBlocks.split(md) == [
                "# Title", "| A | B |\n| - | - |\n| 1 | 2 |", "- one\n  more", "- two", "```\na\n\nb\n```", "End",
            ])
    }

    @Test func nestedListItemsStayWithTheirParent() {
        #expect(MarkdownBlocks.split("- a\n  - b\n    - c\n- d") == ["- a\n  - b\n    - c", "- d"])
    }

    @Test func orderedAndAlternativeBulletsSplit() {
        #expect(MarkdownBlocks.split("1. x\n2) y\n+ z\n* w") == ["1. x", "2) y", "+ z", "* w"])
        // A number without the list punctuation, or with a non-ASCII digit, is not a list item.
        #expect(MarkdownBlocks.split("2024 was good\n١. no") == ["2024 was good\n١. no"])
    }

    @Test func fenceNeedsAMatchingCloserAndKeepsInnerFences() {
        let md = "````\n```\ninner\n```\n````\n\nafter"
        #expect(MarkdownBlocks.split(md) == ["````\n```\ninner\n```\n````", "after"])
        // A tilde fence is not closed by backticks.
        #expect(MarkdownBlocks.split("~~~\na\n```\n\nb\n~~~\n\nc") == ["~~~\na\n```\n\nb\n~~~", "c"])
    }

    @Test func listMarkersInsideACodeBlockDoNotSplit() {
        #expect(MarkdownBlocks.split("```\n- not\n- items\n```") == ["```\n- not\n- items\n```"])
    }

    @Test func anUnterminatedFenceRunsToTheEnd() {
        #expect(MarkdownBlocks.split("intro\n\n```\ncode\n\nmore") == ["intro", "```\ncode\n\nmore"])
    }

    @Test func aFenceEndsTheParagraphBeforeIt() {
        #expect(MarkdownBlocks.split("text\n```\ncode\n```\ntail") == ["text", "```\ncode\n```", "tail"])
    }

    @Test func aBacktickRunWithABacktickInTheInfoStringIsInlineCode() {
        #expect(MarkdownBlocks.split("```x```\n\nb") == ["```x```", "b"])
        #expect(MarkdownBlocks.split("```x``` y\nmore\n\nb") == ["```x``` y\nmore", "b"])
        #expect(MarkdownBlocks.split("~~~a`b\nc\n\nd\n~~~") == ["~~~a`b\nc\n\nd\n~~~"])
    }

    @Test func aFencedBlockIndentedInAListItemStaysWithTheItem() {
        #expect(
            MarkdownBlocks.split("- item\n  ```\n  code\n\n  more\n  ```\n  tail\n- next")
                == ["- item\n  ```\n  code\n\n  more\n  ```\n  tail", "- next"])
        #expect(
            MarkdownBlocks.split("1. item\n   ~~~\n   - not an item\n   ~~~\n\nafter")
                == ["1. item\n   ~~~\n   - not an item\n   ~~~", "after"])
    }

    @Test func aTopLevelFenceAfterAListStillSplitsAndKeepsIndices() {
        #expect(
            MarkdownBlocks.split("- item\n```\ncode\n```\ntail") == ["- item", "```\ncode\n```", "tail"])
    }

    @Test func windowsLineEndingsSplitLikeUnixOnes() {
        #expect(MarkdownBlocks.split("a\r\n\r\n- b\r\n- c") == ["a", "- b", "- c"])
    }

    @Test func blocksAreTrimmedAndSplitIsStable() {
        let blocks = MarkdownBlocks.split("  indented  \n\n\ttabbed\t\n")
        #expect(blocks == ["indented", "tabbed"])
        #expect(MarkdownBlocks.split(blocks.joined(separator: "\n\n")) == blocks)
    }

    @Test func hostileTextIsKeptVerbatim() {
        let md = "<b>x</b>\n\n![a](http://example.invalid/p.png)\n\n\u{202E}rtl\u{200B}"
        #expect(MarkdownBlocks.split(md) == ["<b>x</b>", "![a](http://example.invalid/p.png)", "\u{202E}rtl\u{200B}"])
    }
}
