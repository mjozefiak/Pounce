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
    var commentText: String? {
        if let editorText { return editorText }
        if case .loaded(let snapshot) = comments { return snapshot.headBody }
        return nil
    }

    /// Where the thread's quote is: the cached answer, or (for a thread the cache does not know yet) one search.
    func resolution(of thread: CommentThread) -> AnchorResolution {
        if let cached = resolutions.entries[thread.id] { return cached }
        guard let text = commentText else { return .changed }
        return resolveAnchor(thread.anchor, text)
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

    /// The N of "Revise with N comments": the open threads a run would revise, not the ones it would skip as
    /// "text changed" or "edited after the comment" (the label must not promise more than the run does).
    var revisableCommentCount: Int { resolutions.revisable }

    // MARK: Resolving

    /// Searches every open thread's quote now. Called when the comments are read, when editing ends and, after
    /// typing, once typing paused (`scheduleResolutions`), so a keystroke never costs one search per thread.
    func refreshResolutions() {
        resolutionTask?.cancel()
        resolutionTask = nil
        guard let text = commentText, case .loaded = comments else {
            if resolutions != CommentResolutions() { resolutions = CommentResolutions() }
            return
        }
        var next = CommentResolutions()
        for thread in openThreads { next.entries[thread.id] = resolveAnchor(thread.anchor, text) }
        next.revisable = ReviseUnitPlanner.plan(head: text, threads: openThreads).units.reduce(0) {
            $0 + $1.threadIDs.count
        }
        if next != resolutions { resolutions = next }
    }

    /// Waits for `resolveDelay` without another edit, then searches.
    func scheduleResolutions() {
        resolutionTask?.cancel()
        resolutionTask = Task { [weak self, delay = resolveDelay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refreshResolutions()
        }
    }

    /// Searches now, without waiting for the pause (a test, or a caller that needs the answer).
    func flushResolutions() { refreshResolutions() }
}
