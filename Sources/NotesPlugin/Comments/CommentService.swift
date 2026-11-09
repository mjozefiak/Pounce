import Foundation
import LintelKit

/// Why a comment write did nothing.
enum CommentFailure: Error, Equatable, Sendable {
    /// `plugins.notes.readOnly` or a newer schema: nothing is written.
    case readOnly
    /// The text is empty after cleaning, or the selection is blank or too long to anchor.
    case invalid
    /// The selected text is not in the saved note (it moved under the writer): nothing was written.
    case changed
    /// The comment is longer than `NotesStore.commentLimit`: nothing was written and nothing was cut.
    case tooLong
    /// The selected passage is longer than `CommentAnchors.maxQuoteLength`: nothing was written.
    case selectionTooLong
    /// The thread is not in the document any more.
    case missing
    /// The user cancelled while the write was waiting: nothing was written.
    case cancelled
    case other
}

/// Comment writes (spec "Data Model", `note_comment`): a new thread on a selection, a reply, resolve and reopen,
/// re-anchoring. Every write goes through `NotesStore.write`, so `plugins.notes.readOnly` refuses all of them. UI
/// free: the editor session and the inspector call it, tests call it with a store and an injected clock.
struct CommentService: Sendable {
    /// `nil` for a service of an editor on a layer that was never written: the store is then the writer's, opened
    /// by the first write (lazy-store rule), and only `add` and `reanchor` (which go through the writer) work.
    let store: NotesStore?
    let now: @Sendable () -> Date
    /// The author of the comments the user writes.
    static let userAuthor = NoteAuthor.human.rawValue

    init(store: NotesStore?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    /// Comments on `selection` (UTF-16) of `buffer`, the editor's text. The writer first writes what is typed and
    /// closes the edit session, so the comment's anchor revision is never amended, and seeds the overlay when the
    /// layer has none. The anchor is checked against the saved head: when the selected text is not there, nothing
    /// is written. Returns the new thread's id.
    func add(body: String, selection: NSRange, buffer: String, writer: RevisionWriter) async throws -> Int64 {
        do {
            do {
                return try await addOnce(body: body, selection: selection, buffer: buffer, writer: writer)
            } catch NotesError.guardRejected(let rule) where rule == "anchorRevisionGone" {
                // The head's revision was pruned between reading it and writing the thread: read the head again.
                return try await addOnce(body: body, selection: selection, buffer: buffer, writer: writer)
            }
        } catch {
            throw Self.failure(error)
        }
    }

    private func addOnce(body: String, selection: NSRange, buffer: String, writer: RevisionWriter) async throws
        -> Int64
    {
        guard let clean = NotesStore.cleanComment(body) else { throw CommentFailure.invalid }
        guard clean.count <= NotesStore.commentLimit else { throw CommentFailure.tooLong }
        if selection.length > CommentAnchors.maxQuoteLength { throw CommentFailure.selectionTooLong }
        guard let anchor = CommentAnchors.make(in: buffer, range: selection) else { throw CommentFailure.invalid }
        let head = try await writer.ensureDocument()
        let store = try await writer.openedStore()
        // Escape cancelled the popover while the text was being saved: write no comment.
        try Task.checkCancellation()
        // The anchor is built on the head's own text, so the offsets belong to the revision it names.
        let target: CommentAnchor
        if head.body == buffer {
            target = anchor
        } else if let range = AnchorResolver.resolve(anchor, in: head.body).range,
            let found = CommentAnchors.make(in: head.body, range: range)
        {
            target = found
        } else {
            throw CommentFailure.changed
        }
        return try store.addThread(
            docID: head.docID, author: Self.userAuthor, body: body, anchor: target,
            anchorRevisionID: head.revisionID,
            now: now())
    }

    func reply(docID: Int64, threadID: Int64, body: String) throws {
        do {
            guard let store else { throw CommentFailure.other }
            guard try store.addReply(docID: docID, threadID: threadID, author: Self.userAuthor, body: body, now: now())
            else { throw CommentFailure.missing }
        } catch {
            throw Self.failure(error)
        }
    }

    func setStatus(docID: Int64, threadID: Int64, status: CommentStatus) throws {
        do {
            guard let store else { throw CommentFailure.other }
            guard try store.setThreadStatus(docID: docID, threadID: threadID, status: status, now: now()) else {
                throw CommentFailure.missing
            }
        } catch {
            throw Self.failure(error)
        }
    }

    /// Points a thread at `selection` of `buffer` ("text changed" -> new text). Like `add`, the typed text is
    /// written first and the anchor must be found in the saved head.
    func reanchor(docID: Int64, threadID: Int64, selection: NSRange, buffer: String, writer: RevisionWriter?)
        async throws
    {
        do {
            if selection.length > CommentAnchors.maxQuoteLength { throw CommentFailure.selectionTooLong }
            guard let anchor = CommentAnchors.make(in: buffer, range: selection) else { throw CommentFailure.invalid }
            let head: RevisionWriter.Head
            let store: NotesStore
            if let writer {
                head = try await writer.ensureDocument()
                store = try await writer.openedStore()
            } else if let opened = self.store, let record = try opened.headRevision(of: docID) {
                head = RevisionWriter.Head(docID: docID, revisionID: record.id, body: record.body)
                store = opened
            } else {
                throw CommentFailure.missing
            }
            guard let range = AnchorResolver.resolve(anchor, in: head.body).range,
                let target = CommentAnchors.make(in: head.body, range: range)
            else { throw CommentFailure.changed }
            guard
                try store.reanchorThread(
                    docID: head.docID, threadID: threadID, anchor: target, anchorRevisionID: head.revisionID)
            else { throw CommentFailure.missing }
        } catch {
            throw Self.failure(error)
        }
    }

    static func failure(_ error: Error) -> CommentFailure {
        if let failure = error as? CommentFailure { return failure }
        if error is CancellationError { return .cancelled }
        switch error as? NotesError {
        case .readOnly?, .schemaNewer?: return .readOnly
        case .guardRejected(let rule)? where rule == "emptyComment": return .invalid
        case .guardRejected(let rule)? where rule == "commentTooLong": return .tooLong
        case .guardRejected(let rule)? where rule == "startedAtChanged": return .changed
        case .guardRejected(let rule)? where rule == "anchorRevisionGone": return .changed
        default: return .other
        }
    }
}
