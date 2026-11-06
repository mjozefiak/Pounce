import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct RevisionWriterTests {
    // MARK: Coalescing and flush points

    @Test func typingIsWrittenOnceOneSecondAfterTheLastKeystroke() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("a")
        writer.submit("ab")
        writer.submit("abc")
        await rig.clock.waitForSleeps(3)
        rig.clock.advance(by: .milliseconds(999))
        #expect(try rig.humanRevisions(seed.id).isEmpty)  // the 1 s crash window is exactly 1 s
        rig.clock.advance(by: .milliseconds(1))
        await rig.wrote.wait()
        let humans = try rig.humanRevisions(seed.id)
        #expect(humans.count == 1)
        #expect(humans.first?.body == "abc")
        #expect(try rig.head(seed.id).body == "abc")
    }

    @Test func aKeystrokeRestartsTheTimer() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("a")
        await rig.clock.waitForSleeps(1)
        rig.clock.advance(by: .milliseconds(600))
        writer.submit("ab")
        await rig.clock.waitForSleeps(2)
        rig.clock.advance(by: .milliseconds(600))  // 1.2 s after the first key, 0.6 s after the last
        #expect(try rig.humanRevisions(seed.id).isEmpty)
        rig.clock.advance(by: .milliseconds(400))
        await rig.wrote.wait()
        #expect(try rig.head(seed.id).body == "ab")
    }

    @Test func aFlushPointWritesAtOnceAndTheTimerDoesNothingMore() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("typed")
        #expect(writer.hasPendingText)
        let outcome = try await writer.flush()
        #expect(outcome.revisionID != nil)
        #expect(!writer.hasPendingText)
        #expect(try rig.head(seed.id).body == "typed")
        #expect(try await writer.flush() == .nothing)
    }

    // MARK: Amend until referenced

    @Test func writesInOneSessionAmendTheSameRevision() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("one")
        let first = try await writer.flush()
        writer.submit("one two")
        let second = try await writer.flush()
        guard case .appended(let id) = first, case .amended(let amended) = second else {
            Issue.record("expected append then amend, got \(first) \(second)")
            return
        }
        #expect(id == amended)
        #expect(try rig.humanRevisions(seed.id).count == 1)
        #expect(try rig.head(seed.id).body == "one two")
    }

    @Test func aCommentAnchorStopsTheAmend() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("one")
        let first = try #require(try await writer.flush().revisionID)
        try rig.addComment(doc: seed.id, anchorRevision: first)
        writer.submit("one two")
        let second = try await writer.flush()
        guard case .appended(let next) = second else {
            Issue.record("a referenced revision must not be amended, got \(second)")
            return
        }
        #expect(next != first)
        #expect(try rig.store.revision(id: first)?.body == "one")
    }

    @Test func creatingACommentClosesTheSession() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("one")
        try await writer.flush()
        await writer.closeSession()
        writer.submit("one two")
        guard case .appended = try await writer.flush() else {
            Issue.record("the next keystroke starts a new human revision")
            return
        }
        #expect(try rig.humanRevisions(seed.id).count == 2)
    }

    @Test func fiveMinutesIdleStartsANewRevision() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("one")
        try await writer.flush()
        await rig.clock.waitForSleeps(2)  // the debounce timer (cancelled) and the idle timer
        rig.clock.advance(by: .seconds(299))
        rig.clock.advance(by: .seconds(1))
        await rig.idleClosed.wait()
        writer.submit("one two")
        guard case .appended = try await writer.flush() else {
            Issue.record("after 5 minutes idle a new revision starts")
            return
        }
        #expect(try rig.humanRevisions(seed.id).count == 2)
    }

    @Test func aRestoredFromReferenceIsNeverAmended() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("one")
        let first = try #require(try await writer.flush().revisionID)
        try await writer.closeSession()
        let restored = try await writer.restore(revisionID: seed.headRevisionID)
        #expect(restored > first)
        writer.submit("two")
        guard case .appended = try await writer.flush() else {
            Issue.record("the revision after a Restore is a new one")
            return
        }
        let referenced = try rig.store.isReferenced(seed.headRevisionID, docID: seed.id)
        #expect(referenced)
    }

    // MARK: Seeding

    @Test func theFirstWriteInsertsTheSeedAndTheHumanRevisionTogether() async throws {
        let rig = try DocRig()
        let layer = rig.layer("agent text\n\nsecond", version: "v-rendered")
        let writer = rig.writer(.seed(try rig.plan(layer)))
        writer.submit("agent text\n\nsecond edited")
        let outcome = try await writer.flush()
        guard case .seeded(let docID, _) = outcome else {
            Issue.record("expected a seed, got \(outcome)")
            return
        }
        let revisions = try rig.store.revisions(of: docID)
        #expect(revisions.map(\.author) == ["agent", "human"])
        #expect(revisions.first?.body == "agent text\n\nsecond")
        let document = try #require(try rig.store.document(id: docID))
        #expect(document.sourceVersionSeen == "v-rendered")
        #expect(document.sourceStartedAtMs == NoteTime.milliseconds(rig.started))
        #expect(document.sourceState == .present)
        #expect(document.headRevisionID == revisions.last?.id)
    }

    @Test func aFailedHumanInsertLeavesNoSeedBehind() async throws {
        let rig = try DocRig()
        let writer = rig.writer(.seed(try rig.plan(rig.layer("agent text"))))
        try rig.failNextInsert(body: "boom")
        writer.submit("boom")
        await #expect(throws: (any Error).self) { try await writer.flush() }
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") == nil)
        #expect(writer.hasPendingText)  // kept for the retry
        try rig.clearFault()
        #expect(try await writer.flush().revisionID != nil)
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") != nil)
    }

    @Test func aSourceChangeBetweenRenderAndFirstKeystrokeSeedsWhatWasRenderedAndLeavesAProposal() async throws {
        let rig = try DocRig()
        let rendered = rig.layer("old text", version: "v1")
        let writer = rig.writer(.seed(try rig.plan(rendered)))
        // The source moved on after the editor rendered; the editor froze its snapshot at the first keystroke.
        let newer = rig.layer("new text from the source", version: "v2")
        writer.submit("old text plus typing")
        let docID = try #require(try await writer.flush().docIDOfSeed)
        #expect(try rig.store.revisions(of: docID).first?.body == "old text")
        #expect(try rig.head(docID).body == "old text plus typing")
        let result = try await writer.reconcile(layer: newer)
        guard case .proposed(let proposal) = result else {
            Issue.record("expected a pending proposal, got \(result)")
            return
        }
        #expect(try rig.store.revision(id: proposal)?.state == .proposed)
        #expect(try rig.head(docID).body == "old text plus typing")  // no keystroke lost, head unchanged
    }

    @Test func aSourceChangeBetweenKeystrokeAndFirstWriteDoesTheSame() async throws {
        let rig = try DocRig()
        let writer = rig.writer(.seed(try rig.plan(rig.layer("old text", version: "v1"))))
        writer.submit("old text plus typing")  // buffered, not written yet
        let newer = rig.layer("new text from the source", version: "v2")
        let result = try await writer.reconcile(layer: newer)  // flushes first
        guard case .proposed = result else {
            Issue.record("expected a proposal, got \(result)")
            return
        }
        let docID = try #require(try await writer.docID)
        #expect(try rig.store.revisions(of: docID).first?.body == "old text")
        #expect(try rig.head(docID).body == "old text plus typing")
    }

    @Test func aWriterThatTypedTheSeedBackWritesNothing() async throws {
        let rig = try DocRig()
        let writer = rig.writer(.seed(try rig.plan(rig.layer("same"))))
        writer.submit("same")
        #expect(try await writer.flush() == .nothing)
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") == nil)
    }

    @Test func aRetiredWriterWithoutARowNeverSeeds() async throws {
        let rig = try DocRig()
        let writer = rig.writer(.seed(try rig.plan(rig.layer("text"))))
        writer.retire()
        writer.submit("typed")
        await #expect(throws: NotesError.guardRejected(rule: "detached")) { try await writer.flush() }
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") == nil)
    }

    // MARK: One writer, compare-and-set

    @Test func aLostCompareAndSetKeepsTheTextAsAProposal() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("mine")
        try await writer.flush()
        await writer.closeSession()
        // A head move that did not go through the writer (a defect path).
        let intruder = try rig.store.appendRevision(
            NewNoteRevision(
                docID: seed.id, author: "agent", state: .applied, body: "intruder", now: Date(),
                expectedHeadID: try rig.head(seed.id).id))
        writer.submit("mine again")
        let outcome = try await writer.flush()
        guard case .keptAsProposal(let proposal) = outcome else {
            Issue.record("expected a proposal, got \(outcome)")
            return
        }
        let kept = try #require(try rig.store.revision(id: proposal))
        #expect(kept.state == .proposed)
        #expect(kept.author == "human")
        #expect(kept.body == "mine again")
        #expect(try rig.head(seed.id).id == intruder)  // never auto-applied
        #expect(rig.log.errors.contains { $0.contains(NotesError.casConflict.code) })
        #expect(!rig.log.all.joined().contains("mine again"))
        // A proposed human revision is not user writing; the applied "mine" before it still is.
        #expect(try rig.store.hasUserWriting(seed.id))
    }

    @Test func aDiscardedHumanProposalLeavesAnUntouchedOverlayFollowingTheSource() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text", version: "v1"))
        try rig.store.appendRevision(
            NewNoteRevision(docID: seed.id, author: "human", state: .discarded, body: "lost", now: Date()))
        let writer = rig.writer(.existing(docID: seed.id))
        let result = try await writer.reconcile(layer: rig.layer("regenerated", version: "v2"))
        guard case .applied = result else {
            Issue.record("a discarded proposal is not user writing, got \(result)")
            return
        }
        #expect(try rig.head(seed.id).body == "regenerated")
    }

    @Test func concurrentWritersOfOneDocumentStayConsistent() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        let texts = (0..<40).map { "text \($0)" }
        await withTaskGroup(of: Void.self) { group in
            for text in texts {
                group.addTask {
                    writer.submit(text)
                    _ = try? await writer.flush(closingSession: text.hashValue % 3 == 0)
                }
            }
        }
        try await writer.flush()
        let revisions = try rig.store.revisions(of: seed.id)
        #expect(Set(revisions.map(\.seq)).count == revisions.count)
        #expect(texts.contains(try rig.head(seed.id).body))
        #expect(revisions.filter { $0.state == .proposed }.isEmpty)  // one writer: no compare-and-set loss
        #expect(!writer.hasPendingText)
    }

    // MARK: Flush before every other write

    @Test func aDirtyBufferThenASourceChangeGivesAProposal() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text", version: "v1"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("typed")
        let result = try await writer.reconcile(layer: rig.layer("regenerated", version: "v2"))
        guard case .proposed = result else {
            Issue.record("the human revision must exist before the choice, got \(result)")
            return
        }
        #expect(try rig.head(seed.id).body == "typed")
    }

    @Test func aDirtyBufferThenRestoreRestoresAfterTheFlush() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("typed")
        let restored = try await writer.restore(revisionID: seed.headRevisionID)
        let revisions = try rig.store.revisions(of: seed.id)
        #expect(revisions.map(\.body) == ["seed text", "typed", "seed text"])
        #expect(try rig.head(seed.id).id == restored)
        #expect(revisions.last?.metaJSON?.contains("restored_from") == true)
        #expect(revisions.last?.author == "human")
    }

    @Test func aDirtyBufferThenReviseWritesTheHumanRevisionFirst() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("typed")
        try await writer.appendApplied(
            author: .agent, body: "revised", summary: "Revised 1 blocks from comments",
            metaJSON: NoteMeta.json(["comment_ids": [1]]))
        let revisions = try rig.store.revisions(of: seed.id)
        #expect(revisions.map(\.author) == ["agent", "human", "agent"])
        #expect(try rig.head(seed.id).body == "revised")
    }

    @Test func aProposalNeverMovesTheHead() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        let id = try await writer.appendProposal(author: .agent, body: "proposed text")
        #expect(try rig.store.revision(id: id)?.state == .proposed)
        #expect(try rig.head(seed.id).body == "seed text")
    }

    // MARK: Read-only and faults

    @Test func withTheReadOnlyKeyNoRevisionIsEverWritten() async throws {
        let rig = try DocRig(readOnly: true)
        let writer = rig.writer(.seed(try rig.plan(rig.layer("text"))))
        writer.submit("typed")
        await #expect(throws: NotesError.readOnly) { try await writer.flush() }
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") == nil)
        await #expect(throws: NotesError.readOnly) { try await writer.appendApplied(author: .agent, body: "x") }
        let count = try rig.store.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_revision") }
        #expect(count == 0)
    }

    @Test func aFaultMidWriteLeavesThePreviousHead() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit("good")
        try await writer.flush()
        await writer.closeSession()
        try rig.failNextInsert(body: "bad")
        writer.submit("bad")
        await #expect(throws: (any Error).self) { try await writer.flush() }
        #expect(try rig.head(seed.id).body == "good")
        #expect(try rig.store.revisions(of: seed.id).count == 2)
        try rig.clearFault()
        try await writer.flush()
        #expect(try rig.head(seed.id).body == "bad")
    }

    // MARK: Quit

    @Test func quittingWithADirtyBufferWritesIt() async throws {
        let rig = try DocRig()
        let seed = try rig.seededDocument(rig.layer("seed text"))
        let registry = NoteDocumentRegistry(log: rig.log)
        let id = NoteDocumentID.live(rig.meeting, layer: "notes")
        let writer = registry.writer(for: id, item: .live(rig.meeting)) { rig.writer(.existing(docID: seed.id)) }
        writer.submit("typed before quit")
        await registry.flushAll()  // `deactivate()` does exactly this before the store closes
        #expect(try rig.head(seed.id).body == "typed before quit")
        #expect(registry.writer(for: id, item: .live(rig.meeting)) { rig.writer(.existing(docID: seed.id)) } === writer)
    }

    // MARK: Stored blocks

    @Test func blocksJSONKeepsTheAuthorAndTheProvenanceOfEveryBlock() async throws {
        let rig = try DocRig()
        let provenance = [
            NoteBlockProvenance(blockIndex: 0, speakerID: "s1", startMs: 100, segmentRef: "a"),
            NoteBlockProvenance(blockIndex: 1, speakerID: "s2", startMs: 200, segmentRef: "b"),
        ]
        let layer = rig.layer("first\n\nsecond", id: "transcript", author: .stt, provenance: provenance)
        let writer = rig.writer(.seed(try rig.plan(layer)))
        writer.submit("first\n\nsecond edited")
        let docID = try #require(try await writer.flush().docIDOfSeed)
        let head = try #require(StoredBlocks.decode(try rig.head(docID).blocksJSON))
        #expect(head.blocks.map(\.author) == ["stt", "human"])
        #expect(head.blocks.map(\.segmentRef) == ["a", "b"])  // same count: provenance by index
        // Reverting gives the original author back (content-addressed).
        writer.submit("first\n\nsecond")
        try await writer.flush()
        let reverted = try #require(StoredBlocks.decode(try rig.head(docID).blocksJSON))
        #expect(reverted.blocks.map(\.author) == ["stt", "stt"])
        // A block count change carries provenance by identical text only.
        writer.submit("new block\n\nfirst\n\nsecond")
        try await writer.flush()
        let grown = try #require(StoredBlocks.decode(try rig.head(docID).blocksJSON))
        #expect(grown.blocks.map(\.author) == ["human", "stt", "stt"])
        #expect(grown.blocks.map(\.segmentRef) == [nil, "a", "b"])
    }

    @Test func aTranscriptSeedKeepsTheSpeakersSnapshot() async throws {
        let rig = try DocRig()
        let layer = rig.layer("hello", id: "transcript", author: .stt)
        let speakers = [NoteSpeaker(id: "s1", name: "Ala", isSelf: true)]
        let seed = try OverlaySeeder.seed(try rig.plan(layer, speakers: speakers), in: rig.store, now: Date())
        let first = try #require(try rig.store.revisions(of: seed.id).first)
        let meta = try #require(first.metaJSON)
        #expect(meta.contains("\"speakers\""))
        #expect(meta.contains("Ala"))
        let heads = try NoteOverlayContent.heads(for: .live(rig.meeting), in: rig.store)
        #expect(heads.first?.seedSpeakers == speakers)
    }

    @Test func logsNeverHoldTheNoteText() async throws {
        let rig = try DocRig()
        let secret = "Quarterly layoffs list for Zofia"
        let seed = try rig.seededDocument(rig.layer(secret))
        let writer = rig.writer(.existing(docID: seed.id))
        writer.submit(secret + " and Marek")
        try await writer.flush()
        _ = try? rig.store.appendRevision(
            NewNoteRevision(docID: seed.id, author: "agent", state: .applied, body: "x", now: Date(), expectedHeadID: 0)
        )
        writer.submit(secret + " again")
        _ = try? await writer.flush()
        let all = rig.log.all.joined(separator: "\n")
        #expect(!all.contains("Zofia"))
        #expect(!all.contains("Marek"))
        #expect(!all.contains(rig.meeting.rawValue))
    }
}

extension RevisionWriter.Outcome {
    var docIDOfSeed: Int64? {
        if case .seeded(let docID, _) = self { docID } else { nil }
    }
}
