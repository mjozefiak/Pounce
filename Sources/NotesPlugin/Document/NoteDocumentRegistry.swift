import Foundation
import LintelKit

/// Names one layer document (spec "Data Model"): a live layer of a note, or a detached overlay by its row.
enum NoteDocumentID: Hashable, Sendable {
    case live(NoteKey, layer: String)
    case detached(docID: Int64)
}

/// One `RevisionWriter` per open `NoteDocumentID`, so a note open twice (a tab and a palette or route open) is one
/// document with one buffer and every head-moving write goes through that one writer. It is also what the
/// detacher asks first: an open document is flushed and re-keyed, never deleted while its tab is open.
@MainActor
final class NoteDocumentRegistry {
    private struct Entry {
        var writer: RevisionWriter
        var item: NoteItemID
        /// Counts every `writer(for:)` that handed the entry out again: a release that awaited a flush forgets the
        /// entry only when nobody re-acquired it meanwhile.
        var acquisitions = 0
        /// The tab closed but the last flush failed: the entry (and its buffered text) stays until a flush works.
        var lingering = false
    }

    private var entries: [NoteDocumentID: Entry] = [:]
    private let log: any NotesLogging

    /// Runs after a document was released: deletes the detached rows that are no longer open and have no user
    /// writing and no open comment. Set by the plugin, which owns the store.
    var cleanup: @Sendable (Set<Int64>) async -> Void = { _ in }
    /// A detach re-keyed the open documents of a note: the tab of `.live(key)` is now
    /// `.detached(key, startedAtMs:)` and shows "Recording removed".
    /// Returns `false` when no tab could be moved (it was closed, or the detached tab is already open).
    var onRekey: @MainActor (NoteKey, Int64) -> Bool = { _, _ in true }
    /// A tab closed (or the quit flush ran) while its text could not be written: the text is kept and retried.
    var onSaveFailure: @MainActor (NoteItemID) -> Void = { _ in }

    init(log: any NotesLogging = OSNotesLog()) {
        self.log = log
    }

    /// The writer of a document, made by `make` the first time it is opened.
    func writer(for id: NoteDocumentID, item: NoteItemID, make: () -> RevisionWriter) -> RevisionWriter {
        if var existing = entries[id] {
            existing.acquisitions += 1
            existing.lingering = false
            entries[id] = existing
            return existing.writer
        }
        let writer = make()
        entries[id] = Entry(writer: writer, item: item)
        return writer
    }

    func writer(for id: NoteDocumentID) -> RevisionWriter? { entries[id]?.writer }

    var documentIDs: [NoteDocumentID] { Array(entries.keys) }

    /// The open live layer documents of a note.
    func writers(forKey key: NoteKey) -> [(layer: String, writer: RevisionWriter)] {
        entries.compactMap { id, entry in
            if case .live(let entryKey, let layer) = id, entryKey == key { return (layer, entry.writer) }
            return nil
        }.sorted { $0.layer < $1.layer }
    }

    /// The notes with an open live layer document.
    var openLiveKeys: [NoteKey] {
        var seen = Set<NoteKey>()
        return entries.keys.compactMap { id -> NoteKey? in
            if case .live(let key, _) = id, seen.insert(key).inserted { return key }
            return nil
        }.sorted { $0.rawValue < $1.rawValue }
    }

    /// The rows that are open now (a document that never wrote has none).
    func openDocIDs() async -> Set<Int64> {
        var ids = Set<Int64>()
        for entry in entries.values {
            if let id = await entry.writer.docID { ids.insert(id) }
        }
        return ids
    }

    /// Writes every buffer (window close, quit, `deactivate()`). A write that fails is logged; its text stays in
    /// the writer's buffer, and the entry stays too, so the next flush point or quit tries again.
    func flushAll() async {
        for (id, entry) in Array(entries) {
            do {
                try await entry.writer.flush()
                dropIfLingering(id, entry)
            } catch {
                log.error(NotesLogEvent("flush", code: (error as? NotesError)?.code ?? "flushFailed"))
            }
        }
    }

    private func dropIfLingering(_ id: NoteDocumentID, _ flushed: Entry) {
        guard let current = entries[id], current.lingering, current.acquisitions == flushed.acquisitions else { return }
        entries[id] = nil
    }

    /// A tab closed: flushes its documents, forgets them, then runs the deferred delete of detached rows. A
    /// document whose flush fails is NOT forgotten (its text would be lost): it lingers, is retried by the next
    /// flush point or quit, and `onSaveFailure` says so. A document re-opened while the flush ran is kept.
    func release(item: NoteItemID) async {
        await release(ids: entries.filter { $0.value.item == item }.map(\.key))
    }

    private func release(ids: [NoteDocumentID]) async {
        guard !ids.isEmpty else { return }
        var failed = false
        for id in ids {
            guard let entry = entries[id] else { continue }
            let seen = entry.acquisitions
            do {
                try await entry.writer.flush(closingSession: true)
                if let now = entries[id], now.acquisitions == seen { entries[id] = nil }
            } catch {
                log.error(NotesLogEvent("flush", code: (error as? NotesError)?.code ?? "flushFailed"))
                if var now = entries[id], now.acquisitions == seen {
                    now.lingering = true
                    entries[id] = now
                    failed = true
                    onSaveFailure(now.item)
                }
            }
        }
        _ = failed
        await cleanup(await openDocIDs())
    }

    /// After a detach: the open documents of the key move to `.detached(docID)` (their writers keep their rows, so
    /// typed text lands in the detached document); a live document that had no row yet is retired, because the
    /// snapshot it would seed from belongs to the recording that is gone. When no tab could be moved (it is gone,
    /// or the detached tab exists already) the moved writers are released at once instead of living on unowned.
    func rekey(key: NoteKey, moved: [DetachedRow]) async {
        let started = moved.compactMap(\.startedAtMs).first ?? 0
        var movedIDs: [NoteDocumentID] = []
        for row in moved {
            guard let entry = entries.removeValue(forKey: .live(key, layer: row.layer)) else { continue }
            let id = NoteDocumentID.detached(docID: row.docID)
            entries[id] = Entry(
                writer: entry.writer, item: .detached(key, startedAtMs: started), acquisitions: entry.acquisitions)
            movedIDs.append(id)
        }
        for id in entries.keys {
            if case .live(let entryKey, _) = id, entryKey == key, let entry = entries.removeValue(forKey: id) {
                entry.writer.retire()
            }
        }
        guard !moved.isEmpty else { return }
        if !onRekey(key, started) { await release(ids: movedIDs) }
    }
}

/// The one place that detaches an overlay (merge, open and sweep): asks the registry first, flushes the open
/// documents of the key, moves every live row of the key to `detached` in one transaction, re-keys the open
/// documents, and then deletes what no longer needs to live ("detach means delete" for an overlay without user
/// writing and without an open comment; an open document is deleted only after its tab closes).
struct RegistryOverlayDetacher: OverlayDetacher {
    let store: NotesStore
    let registry: NoteDocumentRegistry

    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws {
        for (_, writer) in await registry.writers(forKey: key) { try await writer.flush() }
        let moved = try store.detachReportingRows(key)
        await registry.rekey(key: key, moved: moved)
        try store.deleteUnkeptDetached(excluding: await registry.openDocIDs())
    }
}
