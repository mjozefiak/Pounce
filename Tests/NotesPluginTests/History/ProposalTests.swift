import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// Spec step 6.3: proposed revisions for Regenerate and source rewrites on edited notes. Apply makes an `applied`
/// revision through compare-and-set, Discard keeps the history, a proposal stays pending until the user decides,
/// and the tab and the History tab say so.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct ProposalTests {
    private func model(_ r: ReconRig) -> NotesWorkspaceModel {
        var environment = NotesWorkspaceModel.Environment(library: r.library, pasteboard: RecordingPasteboard())
        environment.registry = r.registry
        let store = r.store
        environment.overlayHeads = { item in (try? NoteOverlayContent.heads(for: item, in: store)) ?? [] }
        environment.installHistory(store: { store })
        environment.installWriting(
            store: { store }, registry: r.registry, settings: r.rig.harness.settings, clock: r.rig.clock)
        return NotesWorkspaceModel(environment: environment)
    }

    /// An edited notes layer (user writing), then the source writes new notes: a proposal, the head unchanged.
    private func proposed(_ r: ReconRig, regenerated: String = "Regenerated notes.") async throws -> (
        doc: DocumentRecord, proposal: RevisionRecord, head: RevisionRecord
    ) {
        let notes = r.rig.layer("Original notes.", id: "notes", version: "n1")
        let doc = try await r.editedOverlay(notes, text: "My edited notes.")
        let head = try r.rig.head(doc.id)
        r.publish([r.rig.layer(regenerated, id: "notes", version: "n2")])
        guard case .reconciled(let results) = await r.reconciler.reconcile(r.key),
            case .proposed(let id)? = results["notes"]
        else {
            Issue.record("no proposal")
            throw ScriptedError()
        }
        return (doc, try #require(try r.store.revision(id: id)), head)
    }

    // MARK: Writer

    @Test func applyCreatesAnAppliedRevisionOnTopAndKeepsEveryEarlierOne() async throws {
        let r = try ReconRig()
        let (doc, proposal, head) = try await proposed(r)
        let before = try r.store.revisions(of: doc.id)
        let writer = r.rig.writer(.existing(docID: doc.id))
        let id = try await writer.applyProposal(id: proposal.id, expectingHead: head.id)
        let after = try r.store.revisions(of: doc.id)
        #expect(after.count == before.count + 1)
        let applied = try #require(after.last)
        #expect(applied.id == id && applied.state == .applied && applied.author == "agent")
        #expect(applied.body == "Regenerated notes.")
        #expect(try r.rig.head(doc.id).id == id)
        // The text it replaced is still in the chain, and the proposal is no longer pending.
        #expect(after.contains { $0.id == head.id && $0.body == "My edited notes." })
        #expect(after.first { $0.id == proposal.id }?.state == .discarded)
        #expect(NoteHistory.entries(from: after, headID: id).filter(\.isProposal).isEmpty)
        let meta = try #require(
            applied.metaJSON.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(meta["applied_from"] as? Int64 == proposal.id && meta["base_head_id"] as? Int64 == head.id)
    }

    @Test func discardKeepsTheHistoryAndTheHeadAndNeverComesBack() async throws {
        let r = try ReconRig()
        let (doc, proposal, head) = try await proposed(r)
        let writer = r.rig.writer(.existing(docID: doc.id))
        try await writer.discardProposal(id: proposal.id)
        #expect(try r.rig.head(doc.id).id == head.id)
        #expect(try r.store.revision(id: proposal.id)?.state == .discarded)  // the row stays
        // Reconciling the same source version again does not bring it back.
        #expect(await r.reconciler.reconcile(r.key) == .reconciled(["notes": .unchanged]))
        #expect(try r.store.revisions(of: doc.id).filter { $0.state == .proposed }.isEmpty)
        // A second discard is refused: nothing to decide.
        await #expect(throws: NotesError.guardRejected(rule: "proposalTarget")) {
            try await writer.discardProposal(id: proposal.id)
        }
    }

    @Test func aProposalStaysPendingUntilTheUserDecidesAndEveryRewriteAddsOne() async throws {
        let r = try ReconRig()
        let (doc, proposal, _) = try await proposed(r)
        #expect(await r.reconciler.reconcile(r.key) == .reconciled(["notes": .unchanged]))
        r.publish([r.rig.layer("Regenerated again.", id: "notes", version: "n3")])
        _ = await r.reconciler.reconcile(r.key)
        let pending = try r.store.revisions(of: doc.id).filter { $0.state == .proposed }
        #expect(pending.count == 2 && pending.first?.id == proposal.id)
        #expect(try r.rig.head(doc.id).body == "My edited notes.")
    }

    @Test func applyIsCompareAndSetAMovedHeadOrTypedTextWritesNothing() async throws {
        let r = try ReconRig()
        let (doc, proposal, head) = try await proposed(r)
        let writer = r.rig.writer(.existing(docID: doc.id))
        // The user typed after the comparison was made: a new head.
        writer.submit("My edited notes. And more.")
        try await writer.flush(closingSession: true)
        let moved = try r.store.revisions(of: doc.id).count
        await #expect(throws: NotesError.casConflict) {
            try await writer.applyProposal(id: proposal.id, expectingHead: head.id)
        }
        #expect(try r.store.revisions(of: doc.id).count == moved)
        #expect(try r.rig.head(doc.id).body == "My edited notes. And more.")
        // Text that is typed but not written yet is never replaced either.
        let current = try r.rig.head(doc.id).id
        writer.submit("Typed, not saved.")
        await #expect(throws: NotesError.casConflict) {
            try await writer.applyProposal(id: proposal.id, expectingHead: current)
        }
        #expect(writer.hasPendingText)
        #expect(try r.store.revision(id: proposal.id)?.state == .proposed)
    }

    @Test func aRewriteOfNotesNeverTouchesATranscriptWithUserWriting() async throws {
        let r = try ReconRig()
        let notes = r.rig.layer("Original notes.", id: "notes", version: "n1")
        let transcript = r.rig.layer("hello", id: "transcript", version: "t1", author: .stt)
        try await r.editedOverlay(notes, text: "My notes.")
        let doc = try await r.editedOverlay(transcript, text: "hello, fixed by me")
        let head = try r.rig.head(doc.id)
        let count = try r.store.revisions(of: doc.id).count
        r.publish([r.rig.layer("Regenerated notes.", id: "notes", version: "n2"), transcript])
        guard case .reconciled(let results) = await r.reconciler.reconcile(r.key) else {
            Issue.record("not reconciled")
            return
        }
        #expect(results["notes"]?.tag == "proposed" && results["transcript"]?.tag == "unchanged")
        #expect(try r.store.revisions(of: doc.id).count == count)
        #expect(try r.rig.head(doc.id).id == head.id)
        #expect(head.body == "hello, fixed by me")
    }

    @Test func aReviseResultThenASourceRegenerateIsAProposalAndTheHeadStays() async throws {
        let handle = ScriptedReviseHandle([
            .answer(ReviseRig.unit("- Pricing page moves to the next sprint (owner: Marek)."))
        ])
        let rig = try ReviseRig(steps: [.handle(handle)])
        try await rig.comment("next sprint")
        guard case .applied(let applied) = await rig.service.start(rig.request()) else {
            Issue.record("revise did not apply")
            return
        }
        let head = try rig.head()
        #expect(head.id == applied.revisionID)
        let outcome = try await rig.writer.reconcile(layer: rig.rig.layer("Regenerated.", version: "v2"))
        guard case .proposed(let id) = outcome else {
            Issue.record("not a proposal: \(outcome)")
            return
        }
        #expect(try rig.head().id == head.id)
        #expect(head.body.contains("(owner: Marek)."))
        #expect(try rig.rig.store.revision(id: id)?.state == .proposed)
    }

    // MARK: Workspace

    @Test func theTabAndTheHistoryTabShowAPendingProposalAndCompareOffersApplyAndDiscard() async throws {
        let r = try ReconRig()
        let (doc, proposal, head) = try await proposed(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        let document = try #require(model.documents[item])
        #expect(document.totalPendingProposals == 1 && document.pendingProposals == 1)
        model.selectInspectorTab(.history)
        await model.loadHistory(for: item)
        guard case .loaded(let snapshot) = document.history else {
            Issue.record("history not loaded")
            return
        }
        #expect(snapshot.pendingProposals == 1)
        let entry = try #require(snapshot.entries.first { $0.id == proposal.id })
        #expect(entry.isProposal && entry.canCompare && !entry.canRestore && entry.baseID == head.id)
        await model.showCompare(revisionID: proposal.id)
        let compare = try #require(document.compare)
        #expect(compare.proposalID == proposal.id && compare.baseHeadID == head.id)
        #expect(compare.result.lines.map(\.text) == ["My edited notes.", "Regenerated notes."])
        // Apply from Compare.
        await model.applyProposal(revisionID: proposal.id)
        #expect(model.feedback == .proposalApplied)
        #expect(document.compare == nil && document.totalPendingProposals == 0)
        #expect(document.layers.first { $0.id == "notes" }?.markdown == "Regenerated notes.")
        #expect(try r.rig.head(doc.id).body == "Regenerated notes.")
    }

    @Test func discardInTheWorkspaceClearsTheIndicatorsAndKeepsTheText() async throws {
        let r = try ReconRig()
        let (doc, proposal, head) = try await proposed(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        model.selectInspectorTab(.history)
        await model.loadHistory(for: item)
        await model.discardProposal(revisionID: proposal.id)
        let document = try #require(model.documents[item])
        #expect(model.feedback == .proposalDiscarded)
        #expect(document.totalPendingProposals == 0)
        #expect(try r.rig.head(doc.id).id == head.id)
        #expect(try r.store.revision(id: proposal.id) != nil)
    }

    @Test func discardingTheUsersOwnKeptTextAsksFirstAndKeepsItUntilConfirmed() async throws {
        let r = try ReconRig()
        let notes = r.rig.layer("Original notes.", id: "notes", version: "n1")
        r.publish([notes])
        let doc = try await r.editedOverlay(notes, text: "My edited notes.")
        let writer = r.rig.writer(.existing(docID: doc.id))
        let proposalID = try await writer.appendProposal(author: .human, body: "Words I typed.")
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        model.selectInspectorTab(.history)
        await model.loadHistory(for: item)
        let document = try #require(model.documents[item])
        // Discard only asks; nothing is written.
        await model.discardProposal(revisionID: proposalID)
        #expect(document.pendingDiscard == proposalID && model.isDiscardPending(revisionID: proposalID))
        #expect(try r.store.revision(id: proposalID)?.state == .proposed)
        // Keep my text: the question goes away, the proposal stays pending.
        model.cancelDiscard()
        #expect(document.pendingDiscard == nil)
        #expect(try r.store.revision(id: proposalID)?.state == .proposed)
        // A confirmation without a question is ignored.
        await model.confirmDiscard(revisionID: proposalID)
        #expect(try r.store.revision(id: proposalID)?.state == .proposed)
        // Ask, then confirm: discarded, with the confirmation recorded.
        await model.discardProposal(revisionID: proposalID)
        await model.confirmDiscard(revisionID: proposalID)
        #expect(model.feedback == .proposalDiscarded)
        let record = try #require(try r.store.revision(id: proposalID))
        #expect(record.state == .discarded && record.metaJSON?.contains("\"resolved\":1") == true)
        #expect(document.pendingDiscard == nil)
    }

    @Test func theStoreRefusesToDiscardTheUsersOwnKeptTextWithoutTheConfirmation() async throws {
        let r = try ReconRig()
        let notes = r.rig.layer("Original notes.", id: "notes", version: "n1")
        let doc = try await r.editedOverlay(notes, text: "My edited notes.")
        let writer = r.rig.writer(.existing(docID: doc.id))
        let proposalID = try await writer.appendProposal(author: .human, body: "Words I typed.")
        await #expect(throws: NotesError.guardRejected(rule: "discardNeedsConfirmation")) {
            try await writer.discardProposal(id: proposalID)
        }
        #expect(try r.store.revision(id: proposalID)?.state == .proposed)
    }

    @Test func applyAfterTheNoteChangedIsRefusedWithAStripAndWritesNothing() async throws {
        let r = try ReconRig()
        let (doc, proposal, _) = try await proposed(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        model.selectInspectorTab(.history)
        await model.loadHistory(for: item)
        await model.showCompare(revisionID: proposal.id)
        // The head moves after the comparison was made.
        let writer = r.rig.writer(.existing(docID: doc.id))
        writer.submit("Changed meanwhile.")
        try await writer.flush(closingSession: true)
        let count = try r.store.revisions(of: doc.id).count
        await model.applyProposal(revisionID: proposal.id)
        #expect(model.feedback == .proposalChanged)
        #expect(try r.store.revisions(of: doc.id).count == count)
        #expect(try r.store.revision(id: proposal.id)?.state == .proposed)
        #expect(model.strips.contains { $0.id == "feedback" })
    }

    @Test func aDetachedOverlayCannotBeResolved() async throws {
        let r = try ReconRig()
        let (_, _, _) = try await proposed(r)
        let model = model(r)
        let item = NoteItemID.live(r.key)
        model.open(item)
        await model.loadContent(item)
        let document = try #require(model.documents[item])
        let snapshot = HistorySnapshot(docID: 1, layer: "notes", headID: 1, revisions: [], isDetached: true)
        #expect(!model.canResolveProposals(document, snapshot))
    }
}
