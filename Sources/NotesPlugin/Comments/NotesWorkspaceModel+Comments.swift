import Foundation
import LintelKit

/// A comment write the inspector asks for on a loaded thread.
enum CommentWrite: Sendable, Equatable {
    case reply(docID: Int64, threadID: Int64, body: String)
    case setStatus(docID: Int64, threadID: Int64, status: CommentStatus)
}

/// Comments of the open note (step 5.2): read from `notes.sqlite` with the document, written through
/// `CommentService`. The text of a comment never reaches a log.
extension NotesWorkspaceModel {
    /// The comments tab is on screen, or the editor needs the highlights; either way the open note's comments are read.
    func refreshPanes(_ id: NoteItemID) async {
        await refreshHistoryIfShown(id)
        await refreshComments(id)
    }

    /// Reads the comments of the layer the document shows. A reload keeps the list on screen until the new one is in.
    func refreshComments(_ id: NoteItemID) async {
        guard let document = documents[id], let layer = document.layerID else { return }
        if document.comments == .idle { document.setComments(.loading) }
        document.commentEpoch += 1
        let epoch = document.commentEpoch
        let state = await environment.loadComments(id, layer)
        // A newer read started meanwhile: its snapshot is the later one, this one must not overwrite it.
        guard documents[id] === document, document.layerID == layer, document.commentEpoch == epoch else { return }
        document.setComments(state)
    }

    /// Whether the user may comment, reply, resolve and re-anchor here: the store can be written and the document is
    /// not a detached overlay.
    func canWriteComments(_ document: NoteDocumentModel) -> Bool {
        canWriteCommentsIgnoringLock(document) && !document.lock.isActive
    }

    /// The same without the agent's run: "Ask agent" is queued behind a run that is going on, it writes nothing.
    func canWriteCommentsIgnoringLock(_ document: NoteDocumentModel) -> Bool {
        environment.canEditNotes && !document.commentsAreDetached && !isDetached(document)
    }

    private func isDetached(_ document: NoteDocumentModel) -> Bool {
        if case .detached = document.id { true } else { false }
    }

    /// The popover's Comment: a new thread on the selection. `true` when it was written; then the thread is
    /// selected and the Comments tab shows it.
    @discardableResult
    func addComment(body: String, selection: NSRange, buffer: String) async -> Bool {
        guard let id = currentID, let document = documents[id], let session = document.session,
            canWriteComments(document)
        else { return false }
        do {
            let thread = try await session.addComment(body: body, selection: selection, buffer: buffer)
            document.commentFilter = .open
            document.selectedThreadID = thread
            inspectorVisible = true
            inspectorTab = .comments
            await loadContent(id)
            return true
        } catch {
            // Cancelled by the popover (Escape): nothing was written, nothing to say.
            if CommentService.failure(error) != .cancelled { show(feedback(for: error)) }
            return false
        }
    }

    func reply(to thread: CommentThread, body: String) async -> Bool {
        guard let document = currentDocument, canWriteComments(document),
            case .loaded(let snapshot) = document.comments
        else { return false }
        return await write(.reply(docID: snapshot.docID, threadID: thread.id, body: body))
    }

    func setStatus(_ status: CommentStatus, of thread: CommentThread) async {
        guard let document = currentDocument, canWriteComments(document),
            case .loaded(let snapshot) = document.comments
        else { return }
        await write(.setStatus(docID: snapshot.docID, threadID: thread.id, status: status))
    }

    /// "Text changed" -> the editor's selection becomes the thread's new anchor.
    func reanchor(_ thread: CommentThread) async {
        guard let id = currentID, let document = documents[id], let session = document.session,
            canWriteComments(document), case .loaded(let snapshot) = document.comments
        else { return }
        do {
            try await session.reanchor(docID: snapshot.docID, threadID: thread.id)
            await loadContent(id)
        } catch {
            show(feedback(for: error))
        }
    }

    @discardableResult
    private func write(_ change: CommentWrite) async -> Bool {
        guard let id = currentID else { return false }
        if let failure = await environment.writeComment(change) {
            show(feedback(for: failure))
            return false
        }
        await refreshComments(id)
        return true
    }

    private func feedback(for error: Error) -> Feedback {
        feedback(for: CommentService.failure(error))
    }

    private func feedback(for failure: CommentFailure) -> Feedback {
        switch failure {
        case .readOnly: .commentReadOnly
        case .changed: .commentChanged
        case .tooLong: .commentTooLong
        case .selectionTooLong: .commentSelectionTooLong
        case .invalid: .commentSelectionInvalid
        default: .commentFailed
        }
    }
}

extension NotesWorkspaceModel.Environment {
    /// Reads and writes comments (the store opens on the first need). Reads work with `plugins.notes.readOnly`;
    /// writes go through `CommentService`, which the store refuses while it is on.
    @MainActor
    mutating func installComments(
        store: @escaping @MainActor @Sendable () -> NotesStore?,
        exists: @escaping @MainActor @Sendable () -> Bool = { true },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        loadComments = { item, layer in
            guard exists() else { return .none }
            guard let opened = store() else { return .failed }
            return await Task.detached { () -> CommentsState in
                do {
                    let document: DocumentRecord?
                    switch item {
                    case .live(let key): document = try opened.liveDocument(key: key, layer: layer)
                    case .detached(let key, let started):
                        document = try opened.detachedDocuments(key: key, startedAtMs: started).first {
                            $0.layer == layer
                        }
                    }
                    guard let document else { return .none }
                    let threads = CommentThreads.group(try opened.comments(of: document.id))
                    guard !threads.isEmpty else { return .none }
                    let head = try opened.headRevision(of: document.id)
                    return .loaded(
                        CommentsSnapshot(
                            docID: document.id, layer: layer, threads: threads, headBody: head?.body ?? "",
                            isDetached: document.sourceState == .detached))
                } catch {
                    return .failed
                }
            }.value
        }
        writeComment = { change in
            guard let opened = store() else { return .other }
            return await Task.detached { () -> CommentFailure? in
                let service = CommentService(store: opened, now: now)
                do {
                    switch change {
                    case .reply(let docID, let threadID, let body):
                        try service.reply(docID: docID, threadID: threadID, body: body)
                    case .setStatus(let docID, let threadID, let status):
                        try service.setStatus(docID: docID, threadID: threadID, status: status)
                    }
                    return nil
                } catch {
                    return CommentService.failure(error)
                }
            }.value
        }
    }
}
