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
    private(set) var block: Block?
    /// The last write kept the user's text as a proposal (a compare-and-set loss): the UI says so, with Compare.
    private(set) var keptAsProposal = false
    /// The last write failed; the text is still buffered and `retry()` saves it.
    private(set) var saveFailed = false

    var isEditable: Bool { block == nil }

    init(documentID: NoteDocumentID, writer: RevisionWriter, model: NoteDocumentModel?, block: Block?) {
        self.documentID = documentID
        self.writer = writer
        self.model = model
        self.block = block
    }

    /// Builds the session for the layer the editor shows, or `nil` when the layer cannot be edited at all.
    /// An existing overlay stays editable in every state; without one the layer is seeded only when the source's
    /// state allows it (`OverlaySeeder`).
    static func make(
        content: NoteContent, layerID: String, store: NotesStore, registry: NoteDocumentRegistry,
        model: NoteDocumentModel? = nil, readOnly: Bool, clock: any Clock<Duration> = ContinuousClock(),
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
            RevisionWriter(store: store, target: target, clock: clock, now: now, timing: timing, log: log)
        }
        return NoteEditingSession(documentID: id, writer: writer, model: model, block: block)
    }

    /// Wires the editor: every edit goes to the writer, losing focus is a save point.
    func attach(to controller: NoteEditorController) {
        controller.isReadOnly = !isEditable
        controller.onEdit = { [weak self] edit in self?.handle(edit) }
        controller.onFocusChange = { [weak self] focused in
            if !focused { Task { await self?.flush() } }
        }
    }

    /// An edit of the whole buffer. Ignored while the session is blocked (read-only).
    func handle(_ edit: NoteEditorEdit) {
        guard isEditable else { return }
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
}
