import Foundation

/// What the inspector and the editor read from the loaded comments. Pure derivations over `comments`.
extension NoteDocumentModel {
    var commentThreads: [CommentThread] {
        if case .loaded(let snapshot) = comments { snapshot.threads } else { [] }
    }

    var openThreads: [CommentThread] { commentThreads.filter(\.isOpen) }
    var resolvedThreads: [CommentThread] { commentThreads.filter { !$0.isOpen } }

    /// The number on the Comments tab and on "Revise with N comments": threads that are still open.
    var openCommentCount: Int { openThreads.count }

    var shownThreads: [CommentThread] { commentFilter == .open ? openThreads : resolvedThreads }

    /// Comment writes are off on a detached overlay (its recording is gone).
    var commentsAreDetached: Bool {
        if case .loaded(let snapshot) = comments { snapshot.isDetached } else { false }
    }

    /// The text the quotes are looked for in: the editor's buffer while it is open, else the saved head.
    private var commentText: String? {
        if let editorText { return editorText }
        if case .loaded(let snapshot) = comments { return snapshot.headBody }
        return nil
    }

    func resolution(of thread: CommentThread) -> AnchorResolution {
        guard let text = commentText else { return .changed }
        return AnchorResolver.resolve(thread.anchor, in: text)
    }

    /// An open thread whose quote is not in the text any more.
    func isTextChanged(_ thread: CommentThread) -> Bool { resolution(of: thread) == .changed }

    /// Where the open threads are in the editor's text; a thread whose text changed has no highlight.
    var highlights: [CommentHighlight] {
        openThreads.compactMap { thread in
            resolution(of: thread).range.map {
                CommentHighlight(threadID: thread.id, range: $0, isSelected: thread.id == selectedThreadID)
            }
        }
    }
}
