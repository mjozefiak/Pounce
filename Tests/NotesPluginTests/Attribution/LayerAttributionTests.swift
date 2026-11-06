import AppKit
import LintelCore
import LintelKit
import Testing

@testable import NotesPlugin

/// The gutter's rules (spec step 4.3): per-block authors, the marks, the chip rule and the accessibility text.
@Suite struct LayerAttributionTests {
    private let seed = "## Summary\n\nWe ship on Friday. [12:41]\n\n- Budget approved. [12:44]"

    private func revision(
        _ seq: Int, _ author: String, _ body: String, meta: String? = nil, state: NoteRevisionState = .applied
    ) -> RevisionRecord {
        RevisionRecord(
            id: Int64(seq), docID: 1, seq: seq, author: author, state: state, createdAt: Date(timeIntervalSince1970: 0),
            summary: nil, body: body, blocksJSON: nil, metaJSON: meta)
    }

    private func infos(_ chain: [RevisionRecord], head: String, layer: NoteAuthor = .agent) -> [BlockAttributionInfo] {
        LayerAttribution.overlay(layerAuthor: layer, chain: chain, head: nil).infos(blocks: MarkdownBlocks.split(head))
    }

    @Test func aLayerWithoutAnOverlayIsTheSourcesOwnTextEverywhere() {
        let result = LayerAttribution.source(author: .agent).infos(blocks: MarkdownBlocks.split(seed))
        #expect(result.map(\.author) == [.agent, .agent, .agent])
        #expect(result.allSatisfy { $0.mark == nil && $0.showsQuotes })
    }

    @Test func anUntouchedSeedBlockKeepsItsAuthorAndItsChips() {
        let edited = seed.replacingOccurrences(of: "Friday", with: "Monday")
        let result = infos([revision(1, "agent", seed), revision(2, "human", edited)], head: edited)
        #expect(result.map(\.author) == [.agent, .human, .agent])
        #expect(result[0].showsQuotes && result[0].mark == nil)
        #expect(!result[1].showsQuotes && result[1].mark == .addedByYou)
        #expect(result[2].showsQuotes && result[2].mark == nil)
    }

    @Test func aBlockTheAgentRevisedIsMarkedAndLosesItsChipsUnlessItEqualsTheSeed() {
        let revised = seed.replacingOccurrences(of: "Budget approved.", with: "Budget approved for Q4.")
        let result = infos(
            [
                revision(1, "agent", seed),
                revision(2, "agent", revised, meta: #"{"comment_ids":[1]}"#),
            ], head: revised)
        #expect(result[2].mark == .revisedNotChecked)
        #expect(!result[2].showsQuotes)
        #expect(result[1].mark == nil && result[1].showsQuotes)
    }

    @Test func editAndRevertGivesTheChipsBack() {
        let edited = seed.replacingOccurrences(of: "Friday", with: "Monday")
        let result = infos(
            [revision(1, "agent", seed), revision(2, "human", edited), revision(3, "human", seed)], head: seed)
        #expect(result.map(\.author) == [.agent, .agent, .agent])
        #expect(result.allSatisfy { $0.mark == nil && $0.showsQuotes })
    }

    @Test func aBlockASourceRegenerateWroteCountsAsCheckedByTheSource() {
        let regenerated = "## Summary\n\nWe ship on Friday 12 Nov. [12:41]"
        let result = infos(
            [
                revision(1, "agent", seed),
                revision(2, "agent", regenerated, meta: #"{"source_version":"v2"}"#),
            ], head: regenerated)
        #expect(result.allSatisfy { $0.author == .agent && $0.mark == nil && $0.showsQuotes })
    }

    @Test func aProposedRevisionIsNotPartOfTheChain() {
        let proposed = "Something else."
        let result = infos(
            [revision(1, "agent", seed), revision(2, "agent", proposed, state: .proposed)], head: seed)
        #expect(result.allSatisfy { $0.author == .agent && $0.mark == nil })
    }

    @Test func storedAuthorsWinOverTheChainForTheHeadAsWritten() {
        // A Restore keeps the authors it restored: the stored list is what was written, so it is drawn.
        let stored = StoredBlocks(blocks: [StoredBlock(author: "agent"), StoredBlock(author: "human")])
        let layer = LayerAttribution.overlay(
            layerAuthor: .agent, chain: [revision(1, "agent", "A.\n\nB.")], head: stored)
        #expect(layer.infos(blocks: ["A.", "B."]).map(\.author) == [.agent, .human])
        // While typing the stored list does not line up with the buffer, so the chain decides.
        #expect(layer.infos(blocks: ["A.", "B.", "C."]).map(\.author) == [.agent, .agent, .human])
        #expect(layer.infos(blocks: ["A.", "B."], useStored: false).map(\.author) == [.agent, .agent])
    }

    @Test func seedingMeansWhatIsTypedOnTopOfTheRenderedLayerIsHuman() {
        let layer = NoteLayer(id: "notes", author: .agent, markdown: "One.\n\nTwo.", version: "v1")
        let live = LayerAttribution.seeding(layer: layer).infos(
            blocks: ["One.", "Two, edited.", "Three."], useStored: false)
        #expect(live.map(\.author) == [.agent, .human, .human])
        #expect(live.map(\.mark) == [nil, .addedByYou, .addedByYou])
    }

    @Test func aTranscriptLayerHasBarsButNoMarks() {
        let result = infos(
            [revision(1, "stt", "One.\n\nTwo."), revision(2, "human", "One.\n\nTwo!")], head: "One.\n\nTwo!",
            layer: .stt)
        #expect(result.map(\.author) == [.stt, .human])
        #expect(result.allSatisfy { $0.mark == nil && $0.showsQuotes })
    }

    @Test func everyAuthorAndMarkIsSpokenAsWords() {
        #expect(NoteAuthor.agent.spokenName == "Written by AI")
        #expect(NoteAuthor.human.spokenName == "Written by you")
        #expect(NoteAuthor.stt.spokenName == "Speech to text")
        let plain = BlockAttributionInfo(index: 0, author: .agent, mark: nil, showsQuotes: true)
        #expect(plain.spokenLabel == "Written by AI")
        let marked = BlockAttributionInfo(index: 1, author: .human, mark: .addedByYou, showsQuotes: false)
        #expect(marked.spokenLabel == "Written by you, Added by you")
        let revised = BlockAttributionInfo(index: 2, author: .agent, mark: .revisedNotChecked, showsQuotes: false)
        #expect(revised.spokenLabel.hasSuffix("Revised, not checked against the recording"))
        // The words, not the letters: no label is the bare "AI" or "STT".
        for author in AuthorLegend.authors { #expect(author.spokenName.count > 3) }
    }

    @Test func theGutterTextIsAIYouSTT() {
        #expect(NoteAuthor.agent.gutterText == "AI")
        #expect(NoteAuthor.human.gutterText == "You")
        #expect(NoteAuthor.stt.gutterText == "STT")
        #expect(NoteAuthor(rawValue: "future").gutterText.isEmpty)
    }
}

@Suite struct BlockLocatorTests {
    @Test func everyBlockIsFoundInOrderEvenWhenTextRepeats() {
        let text = "Same.\n\nSame.\n\n- Same.\n- Same.\n\n```\nx\n\ny\n```\n"
        let blocks = MarkdownBlocks.split(text)
        let ranges = BlockLocator.ranges(of: blocks, in: text)
        let source = text as NSString
        #expect(ranges.count == blocks.count)
        for (block, range) in zip(blocks, ranges) {
            #expect(range.map { source.substring(with: $0) } == block)
        }
        let starts = ranges.compactMap { $0?.location }
        #expect(starts == starts.sorted() && Set(starts).count == starts.count)
    }

    @Test func textWithCarriageReturnsLosesOnlyTheBlocksItCannotFind() {
        let text = "One.\r\n\r\nTwo.\r\nmore"
        let ranges = BlockLocator.ranges(of: MarkdownBlocks.split(text), in: text)
        #expect(ranges[0] != nil)
        #expect(ranges[1] == nil)
    }

    @Test func accentsAndEmojiUseUTF16Offsets() {
        let text = "Zażółć 😀.\n\nDrugi."
        let ranges = BlockLocator.ranges(of: MarkdownBlocks.split(text), in: text)
        #expect(ranges[1]?.location == ("Zażółć 😀.\n\n" as NSString).length)
    }
}

@MainActor
@Suite("Author gutter", .serialized)
struct AuthorGutterTests {
    private func rig(_ text: String, attribution: @escaping ([String]) -> [BlockAttributionInfo])
        -> (NoteEditorController, AuthorGutterRuler)
    {
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = controller.textView
        let ruler = AuthorGutterRuler(scrollView: scroll, client: controller.textView)
        controller.gutter = ruler
        controller.setText(text)
        controller.attribution = attribution
        return (controller, ruler)
    }

    @Test func theGutterHoldsOneEntryPerBlockWithItsRangeAndAuthor() {
        let (controller, ruler) = rig("One.\n\nTwo.") { blocks in
            blocks.indices.map { index in
                BlockAttributionInfo(index: index, author: index == 0 ? .agent : .human, mark: nil, showsQuotes: true)
            }
        }
        _ = controller
        #expect(ruler.blocks.map(\.range) == [NSRange(location: 0, length: 4), NSRange(location: 6, length: 4)])
        #expect(ruler.blocks.map { $0.info.author } == [.agent, .human])
    }

    @Test func typingASecondBlockAddsAHumanEntryAtOnce() {
        let layer = NoteLayer(id: "notes", author: .agent, markdown: "One.", version: "v1")
        let attribution = LayerAttribution.seeding(layer: layer)
        let (controller, ruler) = rig("One.") { attribution.infos(blocks: $0, useStored: false) }
        #expect(ruler.blocks.map { $0.info.author } == [.agent])
        let end = (controller.text as NSString).length
        controller.textView.setSelectedRange(NSRange(location: end, length: 0))
        controller.textView.insertText("\n\nMine.", replacementRange: NSRange(location: end, length: 0))
        #expect(controller.text == "One.\n\nMine.")
        #expect(ruler.blocks.map { $0.info.author } == [.agent, .human])
        #expect(ruler.blocks.last?.info.mark == .addedByYou)
    }

    @Test func withoutAnAttributionTheGutterIsEmpty() {
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        let ruler = AuthorGutterRuler(scrollView: NSScrollView(), client: controller.textView)
        controller.gutter = ruler
        controller.setText("One.")
        #expect(ruler.blocks.isEmpty)
    }
}

@MainActor
@Suite("Author gutter drawing", .serialized)
struct AuthorGutterDrawingTests {
    @Test func everyVisibleBlockIsMeasuredAndDrawnBesideItsText() throws {
        let controller = NoteEditorController(pasteboard: RecordingPasteboard())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scroll.documentView = controller.textView
        let ruler = AuthorGutterRuler(scrollView: scroll, client: controller.textView)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        window.contentView = scroll
        controller.setWrapsLines(true)
        controller.gutter = ruler
        controller.setText("One.\n\nTwo.\n\nThree.")
        controller.attribution = { blocks in
            blocks.indices.map { BlockAttributionInfo(index: $0, author: .agent, mark: nil, showsQuotes: true) }
        }
        scroll.layoutSubtreeIfNeeded()
        controller.textView.textLayoutManager?.ensureLayout(for: controller.textView.textLayoutManager!.documentRange)
        let rep = try #require(ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds))
        ruler.cacheDisplay(in: ruler.bounds, to: rep)
        #expect(ruler.drawn.count == 3)
        let tops = ruler.drawn.map(\.rect.minY)
        #expect(tops == tops.sorted() && Set(tops).count == 3)
        #expect(ruler.drawn.allSatisfy { $0.rect.height > 0 })
    }
}
