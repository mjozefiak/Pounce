import Foundation
import LintelCore
import LintelKit
import Testing

@testable import NotesPlugin

/// The gutter from the store to the document model and the Details toggles (spec step 4.3).
@MainActor
@Suite("Gutter wiring")
struct GutterWiringTests {
    private let seed = "## Summary\n\nWe ship on Friday. [12:41]\n\n- Budget approved. [12:44]"

    @Test func anOverlaysHeadCarriesWhoWroteEachBlockAndTheDocumentDrawsIt() async throws {
        let rig = try DocRig()
        let layer = rig.layer(seed, provenance: [NoteBlockProvenance(blockIndex: 1, quoteTimesMs: [761_000])])
        let target = RevisionWriter.Target.seed(try rig.plan(layer))
        let writer = rig.writer(target)
        let edited = seed.replacingOccurrences(of: "Friday", with: "Monday")
        writer.submit(edited)
        _ = try await writer.flush()

        let heads = try NoteOverlayContent.heads(for: .live(rig.meeting), in: rig.store)
        let head = try #require(heads.first)
        let attribution = try #require(head.attribution)
        #expect(
            attribution.infos(blocks: MarkdownBlocks.split(head.markdown)).map(\.author) == [.agent, .human, .agent])

        let document = NoteDocumentModel(id: .live(rig.meeting))
        let content = NoteOverlayContent.compose(
            item: .live(rig.meeting), source: rig.content(layers: [layer]), heads: heads, summary: nil)
        document.apply(content, attributions: NoteOverlayContent.attributions(heads: heads))
        #expect(document.blockInfos.map(\.author) == [.agent, .human, .agent])
        #expect(document.info(forBlockAt: 1).mark == .addedByYou)
        #expect(!document.info(forBlockAt: 1).showsQuotes)
        #expect(document.info(forBlockAt: 0).showsQuotes)
    }

    @Test func aLayerWithoutAnOverlayIsDrawnAsTheLayersAuthorAndSwitchingLayersRecomputes() throws {
        let rig = try DocRig()
        let document = NoteDocumentModel(id: .live(rig.meeting))
        let notes = rig.layer(seed)
        let transcript = rig.layer("Hello.\n\nWorld.", id: "transcript", author: .stt)
        document.apply(rig.content(layers: [notes, transcript]))
        #expect(document.blockInfos.map(\.author) == [.agent, .agent, .agent])
        document.selectLayer("transcript")
        #expect(document.blockInfos.map(\.author) == [.stt, .stt])
        #expect(document.info(forBlockAt: 99).author == .stt)
    }

    @Test func theDetailsTtogglesDefaultToOnAndWriteTheirSettingsAtOnce() throws {
        let harness = try NotesHarness()
        let preferences = NoteViewPreferences(settings: harness.settings)
        #expect(preferences.showAuthorBars && preferences.showQuotes && preferences.wrapLines)
        preferences.showAuthorBars = false
        preferences.showQuotes = false
        preferences.wrapLines = false
        let read = harness.notesSettings
        #expect(!read.showAuthorBars && !read.showQuotes && !read.wrapLines)
        // A fresh model reads them back.
        let again = NoteViewPreferences(settings: harness.settings)
        #expect(!again.showAuthorBars && !again.showQuotes && !again.wrapLines)
        // Without settings they stay in memory.
        let loose = NoteViewPreferences()
        loose.showQuotes = false
        #expect(!loose.showQuotes)
    }
}
