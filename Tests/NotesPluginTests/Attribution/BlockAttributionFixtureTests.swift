import Foundation
import LintelCore
import LintelKit
import Testing

@testable import NotesPlugin

/// The Phase 0 fixtures (ADR 0008 addendum 0.3, cases a to e), moved from the prototype that lived in
/// `LintelCoreTests` and run against the real `BlockAttribution`, `LayerAttribution` and `MarkdownBlocks`.
/// Case (e), the per-layer overlay rules, is proven against the real writer and reconciler in
/// `SourceReconcilerTests`; its attribution half (provenance and authors through edits) is here.
@Suite struct BlockAttributionFixtureTests {
    private let seedText = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

    /// The authors of the head's blocks for a chain of applied revisions, oldest first.
    private func authors(_ chain: [(String, String)]) -> [String] {
        let attribution = BlockAttribution(chain: chain.map { (author: $0.0, body: $0.1) })
        let head = chain.last?.1 ?? ""
        return MarkdownBlocks.split(head).map { attribution.author(of: $0) ?? chain.last?.0 ?? "" }
    }

    /// "Untouched": the head's blocks equal the seed revision's blocks.
    private func isUntouched(_ chain: [(String, String)]) -> Bool {
        guard let seed = chain.first, let head = chain.last else { return true }
        return MarkdownBlocks.split(seed.1) == MarkdownBlocks.split(head.1)
    }

    @Test func splitKeepsTablesAndFencesWholeAndSplitsListItems() {
        let md = "# Title\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n- one\n  more\n- two\n\n```\na\n\nb\n```\n\nEnd"
        #expect(
            MarkdownBlocks.split(md) == [
                "# Title", "| A | B |\n| - | - |\n| 1 | 2 |", "- one\n  more", "- two", "```\na\n\nb\n```", "End",
            ])
    }

    @Test func aEditingOneParagraphMarksOnlyThatBlockHuman() {
        let edited = "First paragraph.\n\nSecond paragraph, corrected.\n\nThird paragraph."
        let chain = [("agent", seedText), ("human", edited)]
        #expect(authors(chain) == ["agent", "human", "agent"])
        #expect(!isUntouched(chain))
    }

    @Test func bAddingABlockMarksOnlyTheNewBlockHuman() {
        let added = seedText + "\n\nA new closing thought."
        #expect(authors([("agent", seedText), ("human", added)]) == ["agent", "agent", "agent", "human"])
    }

    @Test func cEditThenRevertGivesTheOriginalAuthorBackAndIsUntouched() {
        let edited = "First paragraph.\n\nSecond paragraph, corrected.\n\nThird paragraph."
        let chain = [("agent", seedText), ("human", edited), ("human", seedText)]
        #expect(authors(chain) == ["agent", "agent", "agent"])
        #expect(isUntouched(chain))
    }

    @Test func dSplitAndMergeMarkTheNewBlocksHuman() {
        let split = "First paragraph.\n\nSecond.\n\nparagraph.\n\nThird paragraph."
        #expect(authors([("agent", seedText), ("human", split)]) == ["agent", "human", "human", "agent"])
        let merged = "First paragraph. Second paragraph.\n\nThird paragraph."
        #expect(authors([("agent", seedText), ("human", merged)]) == ["human", "agent"])
    }

    @Test func aBlockFromAnEarlierHumanRevisionKeepsItsFirstAuthorWhenTheAgentRewritesItLater() {
        let chain = [("agent", "Agent text."), ("human", "Mine."), ("agent", "Agent text.\n\nMine.")]
        #expect(authors(chain) == ["agent", "human"])
    }

    @Test func attributionIsDeterministicAndEmptyChainsAreEmpty() {
        let chain = [("agent", seedText), ("human", seedText + "\n\nMore.")]
        #expect(authors(chain) == authors(chain))
        #expect(authors([]).isEmpty)
        #expect(isUntouched([]))
    }

    // MARK: (e) meeting layers, the attribution half

    private func transcript() -> NoteLayer {
        NoteLayer(
            id: "transcript", author: .stt, markdown: "Good morning everyone.\n\nLet us start with the plan.",
            provenance: [
                NoteBlockProvenance(blockIndex: 0, speakerID: "s1", startMs: 5_000, segmentRef: "11"),
                NoteBlockProvenance(blockIndex: 1, speakerID: "s2", startMs: 65_000, segmentRef: "12"),
            ], version: "v1")
    }

    @Test func eAnEditedTranscriptKeepsSegmentReferencesAndTimestampsThroughABlockCountChange() {
        let layer = transcript()
        let seeded = BlockAttribution.seeded(layer: layer)
        var attribution = BlockAttribution()
        attribution.add(author: "stt", body: layer.markdown)
        let previous = zip(MarkdownBlocks.split(layer.markdown), seeded.blocks).map { ($0, $1) }
        let edited = "Good morning everyone.\n\nA new aside.\n\nLet us start with the plan."
        let stored = attribution.stored(body: edited, author: "human", previous: previous)
        #expect(stored.blocks.map(\.author) == ["stt", "human", "stt"])
        #expect(stored.blocks[0].segmentRef == "11" && stored.blocks[0].startMs == 5_000)
        #expect(stored.blocks[1].segmentRef == nil && stored.blocks[1].startMs == nil)
        #expect(stored.blocks[2].segmentRef == "12" && stored.blocks[2].startMs == 65_000)
    }

    @Test func eTheTranscriptLayerHasNoVerificationPromise() {
        // A transcript overlay with a human block: the bar says "You", and there is nothing to mark or to lose.
        let chain = [
            RevisionRecord(
                id: 1, docID: 1, seq: 1, author: "stt", state: .applied, createdAt: .now, summary: nil,
                body: "One.\n\nTwo.", blocksJSON: nil, metaJSON: nil),
            RevisionRecord(
                id: 2, docID: 1, seq: 2, author: "human", state: .applied, createdAt: .now, summary: nil,
                body: "One.\n\nTwo, corrected.", blocksJSON: nil, metaJSON: nil),
        ]
        let infos = LayerAttribution.overlay(layerAuthor: .stt, chain: chain, head: nil)
            .infos(blocks: ["One.", "Two, corrected."])
        #expect(infos.map(\.author) == [.stt, .human])
        #expect(infos.allSatisfy { $0.mark == nil && $0.showsQuotes })
    }
}
