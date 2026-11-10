import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesPruneTests {
    private func fill(_ rig: DocRig, humans count: Int, agentSeed: Bool = true) throws -> (docID: Int64, ids: [Int64]) {
        let created = try rig.store.insertDocument(.overlay("m1", author: agentSeed ? "agent" : "human"))
        var ids = [created.revisionID]
        for index in 0..<count {
            ids.append(
                try rig.store.appendRevision(
                    NewNoteRevision(
                        docID: created.docID, author: "human", state: .applied, body: "v\(index)", now: Date(),
                        expectedHeadID: ids.last)))
        }
        return (created.docID, ids)
    }

    @Test func aDocumentIsCappedAtTwoHundredAndPrunesTheOldestHumanSnapshots() throws {
        let rig = try DocRig()
        let (docID, ids) = try fill(rig, humans: 209)
        #expect(try rig.store.prune(docID: docID) == 10)
        let remaining = try rig.store.revisions(of: docID)
        #expect(remaining.count == 200)
        #expect(remaining.first?.id == ids[0])  // the first agent revision is never pruned
        #expect(remaining.last?.id == ids.last)  // nor the head
        #expect(remaining.map(\.id).contains(ids[11]))
        #expect(!remaining.map(\.id).contains(ids[1]))
    }

    @Test func discardedRevisionsGoBeforeHumanSnapshots() throws {
        let rig = try DocRig()
        let (docID, ids) = try fill(rig, humans: 199)  // 200 in all
        for index in 0..<3 {
            try rig.store.appendRevision(
                NewNoteRevision(docID: docID, author: "agent", state: .discarded, body: "d\(index)", now: Date()))
        }
        #expect(try rig.store.prune(docID: docID) == 3)
        let remaining = try rig.store.revisions(of: docID)
        #expect(remaining.filter { $0.state == .discarded }.isEmpty)
        #expect(remaining.map(\.id).contains(ids[1]))
    }

    /// Spec: the user's own text is never discarded silently. A `discarded` human proposal whose removal was not
    /// confirmed survives pruning at the cap; one whose removal was confirmed goes like any other discarded row.
    @Test func aDiscardedHumanProposalSurvivesPruningUntilItsRemovalWasConfirmed() throws {
        let rig = try DocRig()
        let (docID, _) = try fill(rig, humans: 199)  // 200 in all
        let kept = try rig.store.appendRevision(
            NewNoteRevision(docID: docID, author: "human", state: .discarded, body: "my words", now: Date()))
        let confirmed = try rig.store.appendRevision(
            NewNoteRevision(docID: docID, author: "human", state: .proposed, body: "gone", now: Date()))
        try rig.store.discardProposal(docID: docID, proposalID: confirmed, confirmedRemoval: true)
        #expect(try rig.store.prune(docID: docID) == 2)
        let ids = Set(try rig.store.revisions(of: docID).map(\.id))
        #expect(ids.contains(kept) && !ids.contains(confirmed))
        // Still there after more writes beyond the cap.
        for index in 0..<30 {
            try rig.store.appendRevision(
                NewNoteRevision(
                    docID: docID, author: "human", state: .applied, body: "w\(index)", now: Date(),
                    expectedHeadID: try rig.head(docID).id))
            try rig.store.prune(docID: docID)
        }
        #expect(try rig.store.revision(id: kept)?.body == "my words")
    }

    @Test func discardingAHumanProposalNeedsTheConfirmationAndRecordsIt() throws {
        let rig = try DocRig()
        let (docID, _) = try fill(rig, humans: 2)
        let proposal = try rig.store.appendRevision(
            NewNoteRevision(docID: docID, author: "human", state: .proposed, body: "typed", now: Date()))
        #expect(throws: NotesError.guardRejected(rule: "discardNeedsConfirmation")) {
            try rig.store.discardProposal(docID: docID, proposalID: proposal)
        }
        #expect(try rig.store.revision(id: proposal)?.state == .proposed)
        #expect(try rig.store.discardProposal(docID: docID, proposalID: proposal, confirmedRemoval: true))
        let record = try #require(try rig.store.revision(id: proposal))
        #expect(record.state == .discarded && record.metaJSON?.contains("\"resolved\":1") == true)
    }

    @Test func aCommentAnchoredToAPrunedRevisionIsReAnchoredFirst() throws {
        let rig = try DocRig()
        let (docID, ids) = try fill(rig, humans: 209)
        try rig.addComment(doc: docID, anchorRevision: ids[2])
        try rig.store.prune(docID: docID)
        let anchor = try rig.store.read { db in
            try Int64.fetchOne(
                db, sql: "SELECT anchor_revision_id FROM note_comment WHERE doc_id = ?", arguments: [docID])
        }
        let kept = Set(try rig.store.revisions(of: docID).map(\.id))
        #expect(try #require(anchor) != ids[2])
        #expect(kept.contains(try #require(anchor)))
        #expect(anchor == ids[0])  // the nearest kept revision by sequence
    }

    @Test func theLastUserWritingAndNamedReferencesSurvive() throws {
        let rig = try DocRig()
        let created = try rig.store.insertDocument(.overlay("m1", author: "agent"))
        var head = created.revisionID
        let human = try rig.store.appendRevision(
            NewNoteRevision(
                docID: created.docID, author: "human", state: .applied, body: "mine", now: Date(), expectedHeadID: head)
        )
        head = human
        for index in 0..<205 {  // more than the cap, none of them user writing
            head = try rig.store.appendRevision(
                NewNoteRevision(
                    docID: created.docID, author: "agent", state: .applied, body: "a\(index)", now: Date(),
                    expectedHeadID: head))
        }
        try rig.store.prune(docID: created.docID)
        #expect(try rig.store.revision(id: human) != nil)  // pruning never removes the last user writing
        #expect(try rig.store.hasUserWriting(created.docID))
    }

    @Test func aRestoredFromTargetIsNotPruned() throws {
        let rig = try DocRig()
        let (docID, ids) = try fill(rig, humans: 207)
        let head = try rig.store.appendRevision(
            NewNoteRevision(
                docID: docID, author: "human", state: .applied, body: "restored",
                metaJSON: NoteMeta.json(["restored_from": ids[1]]),
                now: Date(), expectedHeadID: ids.last))
        _ = head
        try rig.store.prune(docID: docID)
        #expect(try rig.store.revision(id: ids[1]) != nil)
        #expect(try rig.store.revisions(of: docID).count == 200)
    }

    @Test func thePruneOfAWriteRunsFromTheWriter() async throws {
        let rig = try DocRig()
        let (docID, _) = try fill(rig, humans: 199)
        let writer = rig.writer(.existing(docID: docID))
        writer.submit("one more")
        try await writer.flush()
        #expect(try rig.store.revisions(of: docID).count == 200)
        await writer.closeSession()
        writer.submit("and another")
        try await writer.flush()
        #expect(try rig.store.revisions(of: docID).count == 200)
        #expect(try rig.head(docID).body == "and another")
    }
}
