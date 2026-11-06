import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// History, Compare and Restore (spec step 4.5).
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NoteHistoryTests {
    private func model(_ r: ReconRig, writing: Bool = true) -> NotesWorkspaceModel {
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        environment.installHistory(store: { store })
        if writing {
            environment.installWriting(
                store: { store }, registry: r.registry, settings: r.rig.harness.settings, clock: r.rig.clock)
        }
        return NotesWorkspaceModel(environment: environment)
    }

    /// A note whose agent notes were edited twice by the user: seed (agent) then two human revisions.
    private func chain(_ r: ReconRig) async throws -> (doc: DocumentRecord, revisions: [RevisionRecord]) {
        let layer = r.rig.layer("## Decisions\n\nShip on Friday.\n\nMarek owns T2.", version: "n1")
        r.publish([layer])
        let doc = try r.rig.seededDocument(layer)
        let writer = r.rig.writer(.existing(docID: doc.id))
        writer.submit("## Decisions\n\nShip on Thursday.\n\nMarek owns T2.")
        try await writer.flush(closingSession: true)
        writer.submit("## Decisions\n\nShip on Thursday.\n\nMarek owns T2.\n\nAsk legal.")
        try await writer.flush(closingSession: true)
        return (doc, try r.store.revisions(of: doc.id))
    }

    // MARK: The diff

    @Test func aChangedBlockIsOneRemovedAndOneAddedLineWithTheirAuthors() {
        let result = NoteDiff.compare(
            old: "## Decisions\n\nShip on Friday.\n\nKeep.", oldAuthors: ["agent", "agent", "agent"],
            new: "## Decisions\n\nShip on Thursday.\n\nKeep.", newAuthors: ["agent", "human", "agent"])
        #expect(result.lines.map(\.kind) == [.context, .removed, .added])
        #expect(result.lines.map(\.text) == ["## Decisions", "Ship on Friday.", "Ship on Thursday."])
        #expect(result.lines.map(\.author) == [nil, .agent, .human])
        #expect(result.added == 1 && result.removed == 1 && result.edited == 1)
    }

    @Test func equalTextsHaveNoDifferencesAndAHeadingWithoutAChangeIsNotShown() {
        let same = NoteDiff.compare(old: "## A\n\nOne.", oldAuthors: nil, new: "## A\n\nOne.", newAuthors: nil)
        #expect(same.isEmpty && same.lines.isEmpty)
        let far = NoteDiff.compare(
            old: "## A\n\nOne.\n\n## B\n\nTwo.", oldAuthors: nil, new: "## A\n\nOne.\n\n## B\n\nTwo!", newAuthors: nil)
        #expect(far.lines.map(\.text) == ["## B", "Two.", "Two!"])
    }

    @Test func anAddedBlockAndARemovedBlockAreCountedSeparately() {
        let result = NoteDiff.compare(old: "A\n\nB", oldAuthors: nil, new: "A\n\nB\n\nC", newAuthors: nil)
        #expect(result.added == 1 && result.removed == 0 && result.edited == 0)
        let gone = NoteDiff.compare(old: "A\n\nB\n\nC", oldAuthors: nil, new: "A\n\nC", newAuthors: nil)
        #expect(gone.removed == 1 && gone.added == 0 && gone.lines.map(\.kind) == [.removed])
    }

    // MARK: The entries

    @Test func theEntriesListNewestFirstWithTheirChangesAndTheHeadHasNoRestore() async throws {
        let r = try ReconRig()
        let (doc, revisions) = try await chain(r)
        let entries = NoteHistory.entries(from: revisions, headID: try r.rig.head(doc.id).id)
        #expect(entries.count == 3)
        #expect(entries.map(\.author) == [.human, .human, .agent])
        #expect(entries[2].change == .original)
        #expect(entries[1].change == .blocks(edited: 1, added: 0, removed: 0))
        #expect(entries[0].change == .blocks(edited: 0, added: 1, removed: 0))
        #expect(entries[0].isHead && !entries[0].canRestore)
        #expect(entries[1].canRestore && entries[1].canCompare)
        #expect(entries[2].canRestore && !entries[2].canCompare)
    }

    @Test func aDiscardedRevisionIsNotListedAndAProposalCannotBeRestored() throws {
        let revisions = [
            RevisionRecord.stub(id: 1, seq: 1, author: "agent", state: .applied, body: "A"),
            RevisionRecord.stub(id: 2, seq: 2, author: "human", state: .discarded, body: "B"),
            RevisionRecord.stub(id: 3, seq: 3, author: "human", state: .proposed, body: "C"),
        ]
        let entries = NoteHistory.entries(from: revisions, headID: 1)
        #expect(entries.map(\.id) == [3, 1])
        #expect(entries[0].change == .proposed && !entries[0].canRestore && entries[0].canCompare)
    }

    // MARK: Restore

    @Test func restoreAddsAHumanRevisionThatKeepsTheChainAndTheAuthors() async throws {
        let r = try ReconRig()
        let (doc, before) = try await chain(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        model.inspectorTab = .history
        await model.loadContent(item)
        await model.loadHistory(for: item)
        let seed = try #require(before.first)
        await model.restore(revisionID: seed.id)
        let after = try r.store.revisions(of: doc.id)
        // Nothing was removed or rewritten: the old revisions are as they were, one was added on top.
        #expect(after.count == before.count + 1)
        #expect(Array(after.dropLast()) == before)
        let restored = try #require(after.last)
        #expect(restored.author == "human" && restored.state == .applied)
        #expect(restored.body == seed.body)
        #expect(NoteHistoryMeta.restoredFrom(restored.metaJSON) == seed.id)
        #expect(try r.rig.head(doc.id).id == restored.id)
        // The authors come back with the text: the block the agent wrote is the agent's again.
        let stored = try #require(StoredBlocks.decode(restored.blocksJSON))
        #expect(stored.blocks.map(\.author) == ["agent", "agent", "agent"])
        #expect(model.feedback == .restored)
        // The document and the history show it.
        #expect(model.documents[item]?.layers.first?.markdown == seed.body)
        guard case .loaded(let snapshot) = try #require(model.documents[item]).history else {
            Issue.record("history not loaded")
            return
        }
        #expect(snapshot.entries.first?.change == .restored)
        #expect(snapshot.entries.count == 4)
    }

    @Test func restoreReferencesTheRevisionSoItIsNeverPruned() async throws {
        let r = try ReconRig()
        let (doc, before) = try await chain(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        model.inspectorTab = .history
        await model.loadContent(item)
        await model.loadHistory(for: item)
        let seed = try #require(before.first)
        await model.restore(revisionID: seed.id)
        #expect(try r.store.isReferenced(seed.id, docID: doc.id))
    }

    @Test func restoreIsRefusedWhenNotesAreReadOnlyAndNothingIsWritten() async throws {
        let r = try ReconRig()
        let (doc, before) = try await chain(r)
        r.rig.harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly")
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        model.inspectorTab = .history
        await model.loadContent(item)
        await model.loadHistory(for: item)
        await model.restore(revisionID: try #require(before.first).id)
        #expect(try r.store.revisions(of: doc.id) == before)
        #expect(model.feedback == .restoreFailed)
        #expect(model.strips.contains { $0.id == "restore" })
    }

    @Test func aLayerWithoutAnOverlayHasNoHistoryAndADetachedOneCannotBeRestored() async throws {
        let r = try ReconRig()
        r.publish([r.rig.layer("text", version: "n1")])
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        model.inspectorTab = .history
        await model.loadContent(item)
        await model.loadHistory(for: item)
        #expect(model.documents[item]?.history == HistoryState.none)
        let (doc, revisions) = try await chain(r)
        try r.store.detachReportingRows(r.key)
        let detached = NoteItemID.detached(r.key, startedAtMs: NoteTime.milliseconds(r.rig.started))
        model.open(detached)
        await model.loadContent(detached)
        await model.loadHistory(for: detached)
        guard case .loaded(let snapshot) = try #require(model.documents[detached]).history else {
            Issue.record("history not loaded")
            return
        }
        #expect(snapshot.isDetached && snapshot.revisions.count == revisions.count)
        await model.restore(revisionID: try #require(revisions.first).id)
        #expect(try r.store.revisions(of: doc.id).count == revisions.count)
    }

    // MARK: Compare

    @Test func compareShowsTheRevisionAgainstTheOneBeforeAndClosesAgain() async throws {
        let r = try ReconRig()
        let (_, revisions) = try await chain(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        model.inspectorTab = .history
        await model.loadContent(item)
        await model.loadHistory(for: item)
        await model.showCompare(revisionID: revisions[1].id)
        let compare = try #require(model.documents[item]?.compare)
        #expect(compare.baseAuthor == .agent && compare.author == .human)
        #expect(compare.result.lines.map(\.kind) == [.context, .removed, .added])
        #expect(model.pathComponents?.last == "Compare")
        model.closeCompare()
        #expect(model.documents[item]?.compare == nil)
    }

    @Test func theSeedHasNothingToCompareAgainst() async throws {
        let r = try ReconRig()
        let (_, revisions) = try await chain(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        model.inspectorTab = .history
        await model.loadContent(item)
        await model.loadHistory(for: item)
        await model.showCompare(revisionID: try #require(revisions.first).id)
        #expect(model.documents[item]?.compare == nil)
    }
}

extension RevisionRecord {
    static func stub(id: Int64, seq: Int, author: String, state: NoteRevisionState, body: String) -> RevisionRecord {
        RevisionRecord(
            id: id, docID: 1, seq: seq, author: author, state: state,
            createdAt: Date(timeIntervalSince1970: Double(seq)), summary: nil, body: body, blocksJSON: nil,
            metaJSON: nil)
    }
}
