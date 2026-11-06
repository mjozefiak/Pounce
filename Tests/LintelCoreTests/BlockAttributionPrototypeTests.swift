import CryptoKit
import Foundation
import Testing

/// Phase 0, step 0.3 of the Notes spec (`.ai/specs/2026-11-04-notes-workspace.md`): a pure prototype of
/// content-addressed block attribution and of the per-layer overlay rules, proven on revision fixtures.
///
/// Test-only on purpose: `NotesPlugin` and `LintelCore.MarkdownBlocks` do not exist yet. Step 4.3 moves
/// `BlockAttribution` into `Sources/NotesPlugin/Attribution/` and `split` into `Sources/LintelCore/MarkdownBlocks.swift`
/// and keeps these tests as its fixtures. Everything here is deterministic and does no I/O.
private enum Prototype {
    enum Author: String, Equatable { case source, agent, human }

    struct Revision {
        var seq: Int
        var author: Author
        var markdown: String
        /// Block provenance by block index (transcript layers: `segmentRef` and start time).
        var provenance: [Int: Provenance] = [:]
    }

    struct Provenance: Equatable {
        var segmentRef: Int
        var startMs: Int
    }

    struct AttributedBlock: Equatable {
        var text: String
        var author: Author
    }

    /// Blocks are separated by blank lines. A fenced code block and a table stay one block, and every
    /// top-level list item is its own block (with its indented continuation lines).
    static func split(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        var inFence = false
        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { blocks.append(text) }
            current = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inFence { flush() }
                current.append(line)
                inFence.toggle()
                if !inFence { flush() }
                continue
            }
            if inFence {
                current.append(line)
                continue
            }
            if trimmed.isEmpty {
                flush()
            } else if isListItemStart(line) {
                flush()
                current.append(line)
            } else {
                current.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func isListItemStart(_ line: Substring) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") { return true }
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && line.dropFirst(digits.count).hasPrefix(". ")
    }

    /// A block's author is the author of the earliest revision of the chain that contains an identical block.
    /// Pure: the chain in, the head's blocks out.
    static func attribute(_ chain: [Revision]) -> [AttributedBlock] {
        guard let head = chain.max(by: { $0.seq < $1.seq }) else { return [] }
        let ordered = chain.sorted { $0.seq < $1.seq }
        var firstAuthor: [String: Author] = [:]
        for revision in ordered {
            for block in split(revision.markdown) where firstAuthor[block] == nil {
                firstAuthor[block] = revision.author
            }
        }
        return split(head.markdown).map { AttributedBlock(text: $0, author: firstAuthor[$0] ?? head.author) }
    }

    /// "Untouched": the head's blocks equal the seed revision's blocks (the first revision of the chain).
    static func isUntouched(_ chain: [Revision]) -> Bool {
        let ordered = chain.sorted { $0.seq < $1.seq }
        guard let seed = ordered.first, let head = ordered.last else { return true }
        return split(seed.markdown) == split(head.markdown)
    }

    // MARK: Layers

    /// What a source reports for one layer: neither speaker names nor speaker ids are part of `version`.
    struct SourceLayer {
        var markdown: String
        var provenance: [Int: Provenance]
        var version: String {
            var text = markdown
            for index in provenance.keys.sorted() {
                let p = provenance[index]
                text += "\n\(index):\(p?.segmentRef ?? 0):\(p?.startMs ?? 0)"
            }
            return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Overlay {
        var chain: [Revision]
        var seededFromVersion: String
        var pendingProposal: String?

        var head: Revision? { chain.max(by: { $0.seq < $1.seq }) }
        var hasUserWriting: Bool { chain.contains { $0.author == .human } }
    }

    /// The text a layer shows: the overlay's head, or the source's current text when there is no overlay.
    static func shown(overlay: Overlay?, source: SourceLayer) -> String {
        overlay?.head?.markdown ?? source.markdown
    }

    enum Reconciliation: Equatable {
        case nothing
        case autoApply
        case proposal
    }

    /// The rule for one layer when the source's version moved: no overlay, nothing to do; an overlay without
    /// user writing follows the source; an overlay with user writing gets a proposal and keeps its head.
    static func reconcile(_ overlay: inout Overlay?, source: SourceLayer) -> Reconciliation {
        guard var current = overlay, current.seededFromVersion != source.version else { return .nothing }
        defer { overlay = current }
        if current.hasUserWriting {
            current.pendingProposal = source.markdown
            return .proposal
        }
        let seq = (current.head?.seq ?? 0) + 1
        current.chain.append(
            Revision(seq: seq, author: .source, markdown: source.markdown, provenance: source.provenance))
        current.seededFromVersion = source.version
        return .autoApply
    }

    /// A human edit of one layer: seeds the overlay from the source on first use, then adds a revision.
    /// Provenance follows the blocks by index while their count is unchanged and by identical text otherwise.
    static func edit(_ overlay: inout Overlay?, source: SourceLayer, to markdown: String) {
        var current =
            overlay
            ?? Overlay(
                chain: [Revision(seq: 1, author: .source, markdown: source.markdown, provenance: source.provenance)],
                seededFromVersion: source.version)
        let previous = current.head
        let oldBlocks = split(previous?.markdown ?? "")
        let newBlocks = split(markdown)
        var carried: [Int: Provenance] = [:]
        for (index, block) in newBlocks.enumerated() {
            if oldBlocks.count == newBlocks.count, let p = previous?.provenance[index] {
                carried[index] = p
            } else if let old = oldBlocks.firstIndex(of: block), let p = previous?.provenance[old] {
                carried[index] = p
            }
        }
        current.chain.append(
            Revision(seq: (previous?.seq ?? 0) + 1, author: .human, markdown: markdown, provenance: carried))
        overlay = current
    }

    /// Names are resolved at render time through the segment's current speaker, the stored id is a fallback.
    static func speakerName(
        provenance: Provenance, storedSpeaker: Int, currentSpeakerOfSegment: [Int: Int], names: [Int: String]
    ) -> String? {
        names[currentSpeakerOfSegment[provenance.segmentRef] ?? storedSpeaker]
    }
}

@Suite struct BlockAttributionPrototypeTests {
    private let seedText = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."

    private func chain(_ revisions: (Prototype.Author, String)...) -> [Prototype.Revision] {
        revisions.enumerated().map { index, revision in
            Prototype.Revision(seq: index + 1, author: revision.0, markdown: revision.1)
        }
    }

    @Test func splitKeepsTablesAndFencesWholeAndSplitsListItems() {
        let md = "# Title\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n- one\n  more\n- two\n\n```\na\n\nb\n```\n\nEnd"
        #expect(
            Prototype.split(md) == [
                "# Title", "| A | B |\n| - | - |\n| 1 | 2 |", "- one\n  more", "- two", "```\na\n\nb\n```", "End",
            ])
    }

    @Test func aEditingOneParagraphMarksOnlyThatBlockHuman() {
        let edited = "First paragraph.\n\nSecond paragraph, corrected.\n\nThird paragraph."
        let blocks = Prototype.attribute(chain((.agent, seedText), (.human, edited)))
        #expect(blocks.map(\.author) == [.agent, .human, .agent])
        #expect(!Prototype.isUntouched(chain((.agent, seedText), (.human, edited))))
    }

    @Test func bAddingABlockMarksOnlyTheNewBlockHuman() {
        let added = seedText + "\n\nA new closing thought."
        let blocks = Prototype.attribute(chain((.agent, seedText), (.human, added)))
        #expect(blocks.map(\.author) == [.agent, .agent, .agent, .human])
    }

    @Test func cEditThenRevertGivesTheOriginalAuthorBackAndIsUntouched() {
        let edited = "First paragraph.\n\nSecond paragraph, corrected.\n\nThird paragraph."
        let revisions = chain((.agent, seedText), (.human, edited), (.human, seedText))
        #expect(Prototype.attribute(revisions).map(\.author) == [.agent, .agent, .agent])
        #expect(Prototype.isUntouched(revisions))
    }

    @Test func dSplitAndMergeMarkTheNewBlocksHuman() {
        let split = "First paragraph.\n\nSecond.\n\nparagraph.\n\nThird paragraph."
        let afterSplit = Prototype.attribute(chain((.agent, seedText), (.human, split)))
        #expect(afterSplit.map(\.author) == [.agent, .human, .human, .agent])

        let merged = "First paragraph. Second paragraph.\n\nThird paragraph."
        let afterMerge = Prototype.attribute(chain((.agent, seedText), (.human, merged)))
        #expect(afterMerge.map(\.author) == [.human, .agent])
    }

    @Test func aBlockFromAnEarlierHumanRevisionKeepsItsFirstAuthorWhenTheAgentRewritesItLater() {
        let human = "Mine."
        let revisions = chain((.agent, "Agent text."), (.human, human), (.agent, "Agent text.\n\nMine."))
        #expect(Prototype.attribute(revisions).map(\.author) == [.agent, .human])
    }

    @Test func attributionIsDeterministicAndEmptyChainsAreEmpty() {
        let revisions = chain((.agent, seedText), (.human, seedText + "\n\nMore."))
        #expect(Prototype.attribute(revisions) == Prototype.attribute(revisions))
        #expect(Prototype.attribute([]).isEmpty)
        #expect(Prototype.isUntouched([]))
    }

    // MARK: (e) meeting layers

    private func transcript() -> Prototype.SourceLayer {
        // Segment text only: the speaker is resolved at render time through the segment, so the layer's
        // markdown and provenance never contain a name or a speaker id.
        Prototype.SourceLayer(
            markdown: "Good morning everyone.\n\nLet us start with the plan.",
            provenance: [0: .init(segmentRef: 11, startMs: 5_000), 1: .init(segmentRef: 12, startMs: 65_000)])
    }

    private func notes(_ text: String) -> Prototype.SourceLayer {
        Prototype.SourceLayer(markdown: text, provenance: [:])
    }

    @Test func eTranscriptEditWhileNotesAreNoneThenNotesArriveAndRegenerate() {
        var transcriptOverlay: Prototype.Overlay?
        var notesOverlay: Prototype.Overlay?
        let source = transcript()
        let emptyNotes = notes("")

        Prototype.edit(
            &transcriptOverlay, source: source,
            to: "Good morning, everyone.\n\nLet us start with the plan.")
        #expect(transcriptOverlay?.hasUserWriting == true)
        #expect(Prototype.shown(overlay: notesOverlay, source: emptyNotes) == "")

        // Notes arrive, then regenerate: the layer has no overlay, so it shows the new text, never shadowed.
        let firstNotes = notes("## Summary\n\n- Plan agreed")
        #expect(Prototype.reconcile(&notesOverlay, source: firstNotes) == .nothing)
        #expect(Prototype.shown(overlay: notesOverlay, source: firstNotes) == firstNotes.markdown)
        let regenerated = notes("## Summary\n\n- Plan agreed on Friday")
        #expect(Prototype.reconcile(&notesOverlay, source: regenerated) == .nothing)
        #expect(Prototype.shown(overlay: notesOverlay, source: regenerated) == regenerated.markdown)
        #expect(notesOverlay == nil)

        // The transcript overlay kept its provenance (timestamps and segment references) through the edit.
        #expect(transcriptOverlay?.head?.provenance[0] == .init(segmentRef: 11, startMs: 5_000))
        #expect(transcriptOverlay?.head?.provenance[1] == .init(segmentRef: 12, startMs: 65_000))
        #expect(transcriptOverlay?.chain.count == 2)
    }

    @Test func eRegeneratingNotesCreatesNoTranscriptRevisionOrProposal() {
        var transcriptOverlay: Prototype.Overlay?
        Prototype.edit(&transcriptOverlay, source: transcript(), to: "Hello everyone.\n\nLet us start with the plan.")
        let before = transcriptOverlay?.chain.count

        // Notes regenerate: the transcript source layer did not change, so its version is the same.
        let outcome = Prototype.reconcile(&transcriptOverlay, source: transcript())
        #expect(outcome == .nothing)
        #expect(transcriptOverlay?.chain.count == before)
        #expect(transcriptOverlay?.pendingProposal == nil)
    }

    @Test func eFinishChangingTheTranscriptCreatesNoNotesProposalAndLaterNotesFollowTheNormalRule() {
        var notesOverlay: Prototype.Overlay?
        // Finish changes the transcript only; the notes layer has no overlay, so there is nothing to propose.
        #expect(Prototype.reconcile(&notesOverlay, source: notes("")) == .nothing)
        #expect(notesOverlay == nil)

        // Notes are written afterwards and the user starts writing on that layer: a proposal, not an overwrite.
        let written = notes("- Plan agreed")
        Prototype.edit(&notesOverlay, source: written, to: "- Plan agreed\n- Budget: mine")
        let regenerated = notes("- Plan agreed\n- Budget approved")
        #expect(Prototype.reconcile(&notesOverlay, source: regenerated) == .proposal)
        #expect(notesOverlay?.pendingProposal == regenerated.markdown)
        #expect(notesOverlay?.head?.markdown == "- Plan agreed\n- Budget: mine")

        // An overlay without user writing follows the source.
        var untouched: Prototype.Overlay? = Prototype.Overlay(
            chain: [Prototype.Revision(seq: 1, author: .agent, markdown: "- Old", provenance: [:])],
            seededFromVersion: notes("- Old").version)
        #expect(Prototype.reconcile(&untouched, source: notes("- New")) == .autoApply)
        #expect(Prototype.shown(overlay: untouched, source: notes("- New")) == "- New")
        #expect(untouched?.pendingProposal == nil)
    }

    @Test func eASpeakerRenameOrRediarizationChangesNeitherTheVersionNorCreatesAProposal() {
        var overlay: Prototype.Overlay?
        let source = transcript()
        Prototype.edit(&overlay, source: source, to: "Good morning, everyone.\n\nLet us start with the plan.")
        let revisions = overlay?.chain.count

        // Names and speaker ids are not inputs of the layer, so a rename or a second finalization leaves the
        // layer (and its version) as it was and reconcile does nothing.
        #expect(Prototype.reconcile(&overlay, source: transcript()) == .nothing)
        #expect(overlay?.chain.count == revisions)

        let provenance = Prototype.Provenance(segmentRef: 11, startMs: 5_000)
        let before = Prototype.speakerName(
            provenance: provenance, storedSpeaker: 1, currentSpeakerOfSegment: [11: 1], names: [1: "Ja", 2: "Anna"])
        let afterReplan = Prototype.speakerName(
            provenance: provenance, storedSpeaker: 1, currentSpeakerOfSegment: [11: 2], names: [2: "Anna"])
        let fallback = Prototype.speakerName(
            provenance: provenance, storedSpeaker: 1, currentSpeakerOfSegment: [:], names: [1: "Ja"])
        #expect(before == "Ja")
        #expect(afterReplan == "Anna")
        #expect(fallback == "Ja")
    }

    @Test func provenanceSurvivesEditsThatChangeTheBlockCount() {
        var overlay: Prototype.Overlay?
        Prototype.edit(
            &overlay, source: transcript(),
            to: "Good morning everyone.\n\nA new aside.\n\nLet us start with the plan.")
        let head = overlay?.head
        #expect(head?.provenance[0] == .init(segmentRef: 11, startMs: 5_000))
        #expect(head?.provenance[1] == nil)
        #expect(head?.provenance[2] == .init(segmentRef: 12, startMs: 65_000))
    }
}
