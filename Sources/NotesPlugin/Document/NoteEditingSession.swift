import Foundation
import LintelKit
import Observation

/// Connects one editor to its `RevisionWriter` (spec "Saving"): the editor reports edits, the session hands them
/// to the writer, which writes at most 1 s later, and flushes at every save point (blur, tab close, mode switch,
/// window close, `deactivate()`, and before any lock is taken). UI-free, so tests drive it without a window.
///
/// The session keeps the layer exactly as the editor rendered it (`snapshot`); the first edit freezes that
/// snapshot, so the first write seeds from what the user saw, whatever the source did in between.
@MainActor @Observable
final class NoteEditingSession {
    /// Why the editor cannot write, or `nil`.
    enum Block: Equatable {
        /// `plugins.notes.readOnly`, or the store cannot be written.
        case readOnly
        /// No overlay yet and the layer cannot be seeded now (recording, processing, writing, no text).
        case notReady
    }

    let documentID: NoteDocumentID
    let writer: RevisionWriter
    private let model: NoteDocumentModel?
    /// Comment writes of this layer's document (step 5.2); `nil` without a store (QA without one).
    private let comments: CommentService?
    private(set) var block: Block?
    /// The last write kept the user's text as a proposal (a compare-and-set loss): the UI says so, with Compare.
    private(set) var keptAsProposal = false
    /// The last write failed; the text is still buffered and `retry()` saves it.
    private(set) var saveFailed = false

    /// Asked at every edit and save point, so `plugins.notes.readOnly` flipping while the editor is open is seen.
    private let readOnlyNow: (@MainActor () -> Bool)?
    private weak var controller: NoteEditorController?

    /// Typing is off while the agent writes (the edit lock, from `generating` to the end).
    var isEditable: Bool { block == nil && !(readOnlyNow?() ?? false) && !(model?.lock.isLocked ?? false) }

    init(
        documentID: NoteDocumentID, writer: RevisionWriter, model: NoteDocumentModel?, block: Block?,
        readOnlyNow: (@MainActor () -> Bool)? = nil, comments: CommentService? = nil
    ) {
        self.comments = comments
        self.documentID = documentID
        self.writer = writer
        self.model = model
        self.block = block
        self.readOnlyNow = readOnlyNow
        saveFailed = writer.isSaveFailing
        writer.setSaveFailureHandler { [weak self] failed in
            Task { @MainActor in self?.saveFailed = failed }
        }
    }

    /// Builds the session for the layer the editor shows, or `nil` when the layer cannot be edited at all.
    /// An existing overlay stays editable in every state; without one the layer is seeded only when the source's
    /// state allows it (`OverlaySeeder`).
    static func make(
        content: NoteContent, layerID: String, store: NotesStore, registry: NoteDocumentRegistry,
        model: NoteDocumentModel? = nil, readOnly: Bool, readOnlyNow: (@MainActor () -> Bool)? = nil,
        sourceStartedAtMs: (@Sendable () async -> Int64?)? = nil, clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Date = { Date() }, timing: RevisionWriter.Timing = .init(),
        log: any NotesLogging = OSNotesLog()
    ) -> NoteEditingSession? {
        let key = content.summary.id
        let id = NoteDocumentID.live(key, layer: layerID)
        let existing = try? store.liveDocument(key: key, layer: layerID)
        let target: RevisionWriter.Target
        var block: Block?
        if let existing {
            target = .existing(docID: existing.id)
        } else if let plan = OverlaySeeder.plan(content: content, layerID: layerID) {
            target = .seed(plan)
        } else {
            return nil
        }
        if readOnly || store.blockedReason != nil { block = .readOnly }
        let writer = registry.writer(for: id, item: .live(key)) {
            RevisionWriter(
                store: store, target: target, clock: clock, now: now, timing: timing,
                sourceStartedAtMs: sourceStartedAtMs, log: log)
        }
        return NoteEditingSession(
            documentID: id, writer: writer, model: model, block: block, readOnlyNow: readOnlyNow,
            comments: CommentService(store: store, now: now))
    }

    /// Wires the editor: every edit goes to the writer, losing focus is a save point.
    func attach(to controller: NoteEditorController) {
        self.controller = controller
        controller.isReadOnly = !isEditable
        controller.onEdit = { [weak self] edit in self?.handle(edit) }
        controller.onFocusChange = { [weak self] focused in
            self?.controller?.isReadOnly = !(self?.isEditable ?? false)
            if !focused { Task { await self?.flush() } }
        }
    }

    /// An edit of the whole buffer. Ignored while the session is blocked (read-only).
    func handle(_ edit: NoteEditorEdit) {
        guard isEditable else {
            controller?.isReadOnly = true
            return
        }
        if case .live(_, let layer) = documentID { model?.freezeLayer(layer) }
        writer.submit(edit.text)
    }

    /// A save point. Returns the outcome so a caller can tell a proposal from a normal write.
    @discardableResult
    func flush(closingSession: Bool = false) async -> RevisionWriter.Outcome {
        do {
            let outcome = try await writer.flush(closingSession: closingSession)
            saveFailed = false
            if case .keptAsProposal = outcome { keptAsProposal = true }
            return outcome
        } catch {
            saveFailed = true
            return .nothing
        }
    }

    func retry() async { await flush() }

    // MARK: Comments

    /// What the editor selects now and the text it holds, for the Comment button and for re-anchoring.
    var editorSelection: (range: NSRange, buffer: String)? {
        guard let controller else { return nil }
        return (controller.textView.selectedRange(), controller.text)
    }

    var canComment: Bool { isEditable && comments != nil }

    /// A new thread on `selection` of `buffer`. The writer saves what is typed first and seeds the overlay when
    /// the layer has none. Returns the thread's id.
    func addComment(body: String, selection: NSRange, buffer: String) async throws -> Int64 {
        guard isEditable, let comments else { throw CommentFailure.readOnly }
        return try await comments.add(body: body, selection: selection, buffer: buffer, writer: writer)
    }

    /// Points a thread at the editor's current selection ("text changed").
    func reanchor(docID: Int64, threadID: Int64) async throws {
        guard isEditable, let comments, let selection = editorSelection else { throw CommentFailure.readOnly }
        try await comments.reanchor(
            docID: docID, threadID: threadID, selection: selection.range, buffer: selection.buffer, writer: writer)
    }
}
