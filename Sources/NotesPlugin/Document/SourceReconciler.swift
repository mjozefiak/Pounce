import Foundation
import LintelKit

/// Keeps overlays honest about their source (spec "Source reconciliation", "Detaching"): per-layer `version`
/// compare for the documents that are open, and the detach sweep. Any throw from a source means "unknown":
/// nothing is reconciled, nothing is detached.
final class SourceReconciler: Sendable {
    enum OpenResult: Sendable, Equatable {
        /// The source did not answer (off, locked, slow, no source): nothing changed.
        case unavailable
        /// The recording is gone or was recreated: its overlays were detached.
        case detached
        case reconciled([String: RevisionWriter.Reconciliation])
    }

    /// How often the sweep runs after the one on source activation.
    static let sweepInterval: Duration = .seconds(600)

    private let store: NotesStore
    private let library: NoteLibrary
    private let detacher: any OverlayDetacher
    private let registry: NoteDocumentRegistry
    private let clock: any Clock<Duration>
    private let budget: Duration
    private let now: @Sendable () -> Date
    private let log: any NotesLogging

    init(
        store: NotesStore, library: NoteLibrary, detacher: any OverlayDetacher, registry: NoteDocumentRegistry,
        clock: any Clock<Duration> = ContinuousClock(), budget: Duration = SourceFanOut.defaultBudget,
        now: @escaping @Sendable () -> Date = { Date() }, log: any NotesLogging = OSNotesLog()
    ) {
        self.store = store
        self.library = library
        self.detacher = detacher
        self.registry = registry
        self.clock = clock
        self.budget = budget
        self.now = now
        self.log = log
    }

    /// A note was opened (or its source said it changed): reads its content once, detaches overlays written
    /// against another recording BEFORE any seed or write, then reconciles each overlaid layer by its own version.
    @discardableResult
    func reconcile(_ key: NoteKey) async -> OpenResult {
        // Only a note with an overlay needs its content read here.
        let documents: [DocumentRecord]
        do {
            documents = try store.liveDocuments(key: key)
        } catch {
            return .unavailable
        }
        guard !documents.isEmpty else { return .reconciled([:]) }
        guard let source = await library.source(for: key) else { return .unavailable }
        let outcome = await SourceFanOut.call(budget: budget, clock: clock) { try await source.content(for: key) }
        let content: NoteContent
        switch outcome {
        case .value(let value):
            guard let value else { return await detach(key, reason: .sourceGone) }
            content = value
        case .failed, .timedOut, .cancelled:
            return .unavailable
        }
        let started = NoteTime.milliseconds(content.summary.startedAt)
        if documents.contains(where: { $0.sourceStartedAtMs.map { $0 != started } ?? false }) {
            return await detach(key, reason: .startedAtChanged(sourceStartedAtMs: started))
        }
        var results: [String: RevisionWriter.Reconciliation] = [:]
        for document in documents {
            guard let layer = content.layers.first(where: { $0.id == document.layer }) else { continue }
            let writer =
                await registry.writer(for: .live(key, layer: document.layer))
                ?? RevisionWriter(store: store, target: .existing(docID: document.id), clock: clock, now: now, log: log)
            do {
                results[document.layer] = try await writer.reconcile(layer: layer)
            } catch {
                log.error(
                    NotesLogEvent(
                        "reconcile", code: (error as? NotesError)?.code ?? "reconcileFailed", key: key.rawValue))
            }
        }
        return .reconciled(results)
    }

    private func detach(_ key: NoteKey, reason: OverlayDetachReason) async -> OpenResult {
        do {
            try await detacher.detach(key, reason: reason)
            return .detached
        } catch {
            log.error(NotesLogEvent("detach", code: (error as? NotesError)?.code ?? "detachFailed", key: key.rawValue))
            return .unavailable
        }
    }

    /// A `makeChanges()` event: only the notes with an open document are read, so 1000 overlays and 50 events cost
    /// at most one `content(for:)` per open note and event. Every other overlay is reconciled when opened
    /// (`source_version_seen` is persisted, so nothing is missed).
    func reconcileOpenDocuments() async {
        for key in await registry.openLiveKeys { await reconcile(key) }
    }

    /// The detach sweep (`exists` in batches of 500, only through an open source) followed by the persistent
    /// delete of detached rows that are neither kept nor open. Returns the keys it detached.
    @discardableResult
    func sweep() async -> [NoteKey] {
        let detached = await library.sweep()
        do {
            try store.applyRetention(excluding: await registry.openDocIDs(), now: now())
        } catch {
            log.error(NotesLogEvent("sweep", code: (error as? NotesError)?.code ?? "sweepFailed"))
        }
        return detached
    }

    /// Runs on source activation, then every 10 minutes on the injected clock, until cancelled.
    func runSweeps(every interval: Duration = SourceReconciler.sweepInterval) async {
        while !Task.isCancelled {
            await sweep()
            do { try await clock.sleep(for: interval) } catch { return }
        }
    }
}
