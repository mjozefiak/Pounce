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
    }

    private var entries: [NoteDocumentID: Entry] = [:]
    private let log: any NotesLogging

    /// Runs after a document was released: deletes the detached rows that are no longer open and have no user
    /// writing and no open comment. Set by the plugin, which owns the store.
    var cleanup: @Sendable (Set<Int64>) async -> Void = { _ in }
    /// A detach re-keyed the open documents of a note: the tab of `.live(key)` is now
    /// `.detached(key, startedAtMs:)` and shows "Recording removed".
    var onRekey: @MainActor (NoteKey, Int64) -> Void = { _, _ in }

    init(log: any NotesLogging = OSNotesLog()) {
        self.log = log
    }

    /// The writer of a document, made by `make` the first time it is opened.
    func writer(for id: NoteDocumentID, item: NoteItemID, make: () -> RevisionWriter) -> RevisionWriter {
        if let existing = entries[id] { return existing.writer }
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
    /// the writer's buffer.
    func flushAll() async {
        for entry in Array(entries.values) {
            do {
                try await entry.writer.flush()
            } catch {
                log.error(NotesLogEvent("flush", code: (error as? NotesError)?.code ?? "flushFailed"))
            }
        }
    }

    /// A tab closed: flushes its documents, forgets them, then runs the deferred delete of detached rows.
    func release(item: NoteItemID) async {
        let ids = entries.filter { $0.value.item == item }.map(\.key)
        guard !ids.isEmpty else { return }
        for id in ids {
            if let entry = entries[id] {
                do {
                    try await entry.writer.flush(closingSession: true)
                } catch {
                    log.error(NotesLogEvent("flush", code: (error as? NotesError)?.code ?? "flushFailed"))
                }
            }
            entries[id] = nil
        }
        await cleanup(await openDocIDs())
    }

    /// After a detach: the open documents of the key move to `.detached(docID)` (their writers keep their rows, so
    /// typed text lands in the detached document); a live document that had no row yet is retired, because the
    /// snapshot it would seed from belongs to the recording that is gone.
    func rekey(key: NoteKey, moved: [DetachedRow]) {
        for row in moved {
            guard let entry = entries.removeValue(forKey: .live(key, layer: row.layer)) else { continue }
            entries[.detached(docID: row.docID)] = Entry(
                writer: entry.writer, item: .detached(key, startedAtMs: row.startedAtMs ?? 0))
        }
        for id in entries.keys {
            if case .live(let entryKey, _) = id, entryKey == key, let entry = entries.removeValue(forKey: id) {
                entry.writer.retire()
            }
        }
        if let started = moved.compactMap(\.startedAtMs).first { onRekey(key, started) }
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
