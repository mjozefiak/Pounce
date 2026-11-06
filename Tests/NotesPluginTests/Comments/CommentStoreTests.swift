import Foundation
import GRDB
import LintelKit
import Testing

@testable import NotesPlugin

/// Spec step 5.1: the `note_comment` store and the writes around it, with an injected clock and a temporary store.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CommentStoreTests {
    private let notes = "## Decisions\n\n- Ship onboarding on 12 Nov.\n- Pricing page moves to the next sprint."

    private func range(of quote: String, in text: String) -> NSRange { (text as NSString).range(of: quote) }

    /// A seeded overlay with a writer, as the editor session builds them for a layer without an overlay.
    private func rig(readOnly: Bool = false) throws -> (DocRig, RevisionWriter, CommentService) {
        let rig = try DocRig(readOnly: readOnly)
        let plan = try rig.plan(rig.layer(notes))
        let writer = rig.writer(.seed(plan))
        return (rig, writer, CommentService(store: rig.store, now: { Date(timeIntervalSince1970: 1_800_000_100) }))
    }

    @Test func aCommentWithoutEditingSeedsTheOverlayAndAnchorsToItsHead() async throws {
        let (rig, writer, service) = try rig()
        let thread = try await service.add(
            body: "Which sprint?", selection: range(of: "next sprint", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        let revisions = try rig.store.revisions(of: doc.id)
        #expect(revisions.count == 1)  // only the seed: no human revision was written
        let comments = try rig.store.comments(of: doc.id)
        #expect(comments.count == 1)
        #expect(comments[0].threadID == thread)
        #expect(comments[0].anchorRevisionID == revisions[0].id)
        #expect(comments[0].anchor.quote == "next sprint")
        #expect(comments[0].status == .open)
        #expect(comments[0].author == "human")
        #expect(try rig.store.openThreadCount(of: doc.id) == 1)
        // The overlay is kept by the open comment (spec "Retention").
        #expect(!(try rig.store.hasUserWriting(doc.id)))
    }

    @Test func aCommentFlushesTypedTextFirstAndNeverAmendsItsAnchorRevision() async throws {
        let (rig, writer, service) = try rig()
        let typed = notes + "\n- A line typed a moment ago."
        writer.submit(typed)
        let thread = try await service.add(
            body: "Check this", selection: range(of: "typed a moment", in: typed), buffer: typed, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        let comment = try #require(try rig.store.comments(of: doc.id).first)
        #expect(comment.threadID == thread)
        #expect(try rig.head(doc.id).id == comment.anchorRevisionID)
        #expect(try rig.head(doc.id).body == typed)
        // Typing on after the comment starts a new revision: the referenced one is not amended.
        writer.submit(typed + " more")
        try await writer.flush()
        #expect(try rig.store.revision(id: comment.anchorRevisionID)?.body == typed)
        #expect(try rig.head(doc.id).id != comment.anchorRevisionID)
    }

    @Test func repliesRepeatTheAnchorAndResolveAndReopenTheWholeThread() async throws {
        let (rig, writer, service) = try rig()
        let thread = try await service.add(
            body: "Which sprint?", selection: range(of: "next sprint", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        try service.reply(docID: doc.id, threadID: thread, body: "  Sprint 47.  ")
        var comments = try rig.store.comments(of: doc.id)
        #expect(comments.map(\.body) == ["Which sprint?", "Sprint 47."])
        #expect(comments[1].anchor == comments[0].anchor)
        try service.setStatus(docID: doc.id, threadID: thread, status: .resolved)
        comments = try rig.store.comments(of: doc.id)
        #expect(comments.allSatisfy { $0.status == .resolved })
        #expect(comments.allSatisfy { $0.resolvedAt == Date(timeIntervalSince1970: 1_800_000_100) })
        #expect(try rig.store.openThreadCount(of: doc.id) == 0)
        try service.setStatus(docID: doc.id, threadID: thread, status: .open)
        #expect(try rig.store.comments(of: doc.id).allSatisfy { $0.status == .open && $0.resolvedAt == nil })
        #expect(try rig.store.openThreadCount(of: doc.id) == 1)
    }

    @Test func threadIdsGrowPerDocumentAndCountOnlyOpenThreads() async throws {
        let (rig, writer, service) = try rig()
        let a = try await service.add(
            body: "one", selection: range(of: "Ship", in: notes), buffer: notes, writer: writer)
        let b = try await service.add(
            body: "two", selection: range(of: "Pricing", in: notes), buffer: notes, writer: writer)
        #expect(b == a + 1)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        try service.reply(docID: doc.id, threadID: a, body: "reply")  // a reply is not another thread
        #expect(try rig.store.openThreadCount(of: doc.id) == 2)
        try service.setStatus(docID: doc.id, threadID: a, status: .resolved)
        #expect(try rig.store.openThreadCount(of: doc.id) == 1)
    }

    @Test func emptyCommentsAndBadSelectionsWriteNothing() async throws {
        let (rig, writer, service) = try rig()
        await #expect(throws: CommentFailure.invalid) {
            try await service.add(
                body: " \n\u{202E} ", selection: range(of: "Ship", in: notes), buffer: notes, writer: writer)
        }
        await #expect(throws: CommentFailure.invalid) {
            try await service.add(
                body: "x", selection: NSRange(location: 3, length: 0), buffer: notes, writer: writer)
        }
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") == nil)  // not even the overlay
        await #expect(throws: CommentFailure.missing) {
            try service.reply(docID: 999, threadID: 1, body: "x")
        }
    }

    @Test func bidiAndControlCharactersAreStrippedFromComments() async throws {
        let (rig, writer, service) = try rig()
        _ = try await service.add(
            body: "a\u{202E}b\u{200B}c", selection: range(of: "Ship", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        #expect(try rig.store.comments(of: doc.id).first?.body == "abc")
    }

    @Test func readOnlyRefusesEveryCommentWrite() async throws {
        let (rig, writer, service) = try rig()
        let thread = try await service.add(
            body: "Which sprint?", selection: range(of: "next sprint", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        // `plugins.notes.readOnly` applies at once, to a store that is already open.
        rig.harness.settingsStore.setValue(.bool(true), forKey: "plugins.notes.readOnly")
        let transcript = "Kasia: hello there"
        let other = rig.writer(.seed(try rig.plan(rig.layer(transcript, id: "transcript"))))
        await #expect(throws: CommentFailure.readOnly) {
            try await service.add(
                body: "x", selection: range(of: "hello", in: transcript), buffer: transcript, writer: other)
        }
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "transcript") == nil)  // not even a seed
        #expect(throws: CommentFailure.readOnly) { try service.reply(docID: doc.id, threadID: thread, body: "x") }
        #expect(throws: CommentFailure.readOnly) {
            try service.setStatus(docID: doc.id, threadID: thread, status: .resolved)
        }
        await #expect(throws: CommentFailure.readOnly) {
            try await service.reanchor(
                docID: doc.id, threadID: thread, selection: range(of: "Ship", in: notes), buffer: notes, writer: nil)
        }
        let comments = try rig.store.comments(of: doc.id)
        #expect(comments.count == 1)
        #expect(comments[0].status == .open)
        #expect(comments[0].anchor.quote == "next sprint")
    }

    @Test func aSelectionNotInTheSavedHeadIsRefused() async throws {
        let (rig, writer, service) = try rig()
        // The buffer the editor shows has text the writer never got (nothing was submitted): it cannot be anchored.
        let phantom = notes + "\n\nNever submitted."
        await #expect(throws: CommentFailure.changed) {
            try await service.add(
                body: "x", selection: range(of: "Never submitted", in: phantom), buffer: phantom, writer: writer)
        }
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        #expect(try rig.store.comments(of: doc.id).isEmpty)
    }

    @Test func reanchoringPointsAThreadAtNewTextOfTheHead() async throws {
        let (rig, writer, service) = try rig()
        let thread = try await service.add(
            body: "Which sprint?", selection: range(of: "next sprint", in: notes), buffer: notes, writer: writer)
        let edited = notes.replacingOccurrences(of: "next sprint", with: "week 46")
        writer.submit(edited)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        let before = try #require(try rig.store.comments(of: doc.id).first)
        #expect(AnchorResolver.resolve(before.anchor, in: edited) == .changed)
        try await service.reanchor(
            docID: doc.id, threadID: thread, selection: range(of: "week 46", in: edited), buffer: edited, writer: writer
        )
        let after = try #require(try rig.store.comments(of: doc.id).first)
        #expect(after.anchor.quote == "week 46")
        #expect(after.anchorRevisionID == (try rig.head(doc.id)).id)
        #expect(after.anchorRevisionID != before.anchorRevisionID)
        #expect(AnchorResolver.resolve(after.anchor, in: edited).range == range(of: "week 46", in: edited))
    }

    @Test func aStoredAnchorResolvesAfterTheTextBeforeItChanged() async throws {
        let (rig, writer, service) = try rig()
        _ = try await service.add(
            body: "Which sprint?", selection: range(of: "next sprint", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        let comment = try #require(try rig.store.comments(of: doc.id).first)
        let edited = "## A new title\n\nA paragraph that shifts every offset.\n\n" + notes
        let found = try #require(AnchorResolver.resolve(comment.anchor, in: edited).range)
        #expect((edited as NSString).substring(with: found) == "next sprint")
        let deleted = notes.replacingOccurrences(of: "next sprint", with: "")
        #expect(AnchorResolver.resolve(comment.anchor, in: deleted) == .changed)
    }

    @Test func aCommentedRevisionPrunedAwayMovesItsCommentToANearbyOne() async throws {
        let (rig, writer, service) = try rig()
        let thread = try await service.add(
            body: "x", selection: range(of: "Ship", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        let anchorRevision = try #require(try rig.store.comments(of: doc.id).first).anchorRevisionID
        var head = try rig.head(doc.id).id
        for index in 0..<210 {
            head = try rig.store.appendRevision(
                NewNoteRevision(
                    docID: doc.id, author: "human", state: .applied, body: notes + "\(index)", now: Date(),
                    expectedHeadID: head))
        }
        try rig.store.prune(docID: doc.id)
        let comment = try #require(try rig.store.comments(of: doc.id).first)
        #expect(comment.threadID == thread)
        #expect(try rig.store.revision(id: comment.anchorRevisionID) != nil)
        // The anchor still finds its text: the quote, not the revision, is what re-anchors.
        #expect(AnchorResolver.resolve(comment.anchor, in: try rig.head(doc.id).body).range != nil)
        _ = anchorRevision
    }

    @Test func deletingTheDocumentRemovesItsComments() async throws {
        let (rig, writer, service) = try rig()
        _ = try await service.add(body: "x", selection: range(of: "Ship", in: notes), buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        try rig.store.write { db in try db.execute(sql: "DELETE FROM note_doc WHERE id = ?", arguments: [doc.id]) }
        #expect(try rig.store.comments(of: doc.id).isEmpty)
    }

    @Test func commentTextNeverReachesTheLog() async throws {
        let (rig, writer, service) = try rig()
        let secret = "SECRET-COMMENT-BODY"
        _ = try await service.add(
            body: secret, selection: range(of: "Ship", in: notes), buffer: notes, writer: writer)
        #expect(!rig.log.all.joined().contains(secret))
        #expect(!rig.log.all.joined().contains("Ship onboarding"))
    }
}

/// Review fix (M1): a long comment is refused, never cut; Escape writes nothing.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct CommentLimitTests {
    private let notes = "## Decisions\n\n- Ship onboarding on 12 Nov.\n- Pricing page moves to the next sprint."

    private func rig() throws -> (DocRig, RevisionWriter, CommentService) {
        let rig = try DocRig(readOnly: false)
        let writer = rig.writer(.seed(try rig.plan(rig.layer(notes))))
        return (rig, writer, CommentService(store: rig.store, now: { Date(timeIntervalSince1970: 1_800_000_100) }))
    }

    @Test func aCommentAtTheLimitIsKeptWholeAndOneOverIsRefused() async throws {
        let (rig, writer, service) = try rig()
        let range = (notes as NSString).range(of: "Ship")
        let exact = String(repeating: "ą", count: NotesStore.commentLimit)
        let thread = try await service.add(body: exact, selection: range, buffer: notes, writer: writer)
        let doc = try #require(try rig.store.liveDocument(key: rig.meeting, layer: "notes"))
        #expect(try rig.store.comments(of: doc.id).first?.body == exact)
        await #expect(throws: CommentFailure.tooLong) {
            try await service.add(body: exact + "x", selection: range, buffer: notes, writer: writer)
        }
        #expect(throws: CommentFailure.tooLong) {
            try service.reply(docID: doc.id, threadID: thread, body: exact + "x")
        }
        #expect(try rig.store.comments(of: doc.id).count == 1)  // nothing was cut and saved
        #expect(NotesStore.commentLength(of: "  " + exact + "x ") == NotesStore.commentLimit + 1)
    }

    @Test func aSelectionAboveTheCapIsReportedAsTooLongAndWritesNothing() async throws {
        let (rig, writer, service) = try rig()
        let long = String(repeating: "word ", count: 500)
        await #expect(throws: CommentFailure.selectionTooLong) {
            try await service.add(
                body: "x", selection: NSRange(location: 0, length: CommentAnchors.maxQuoteLength + 1), buffer: long,
                writer: writer)
        }
        #expect(try rig.store.liveDocument(key: rig.meeting, layer: "notes") == nil)
    }

    @Test func aCancelledAddWritesNoComment() async throws {
        let (rig, writer, service) = try rig()
        let range = (notes as NSString).range(of: "Ship")
        let task = Task { () -> Int64? in
            withUnsafeCurrentTask { $0?.cancel() }  // Escape arrives while the text is being saved
            return try? await service.add(body: "x", selection: range, buffer: notes, writer: writer)
        }
        #expect(await task.value == nil)
        let doc = try rig.store.liveDocument(key: rig.meeting, layer: "notes")
        #expect(try doc.map { try rig.store.comments(of: $0.id).count } ?? 0 == 0)
    }
}
