import Foundation
import LintelKit

/// Deletes one note (spec "Delete"). The owner's own deletion comes FIRST; the overlays in `notes.sqlite` go only
/// after it succeeded, so a source that refuses (an active meeting) or fails (its store is locked or off) leaves
/// everything as it was, and a failed overlay removal is never mistaken for a deleted note. The caller has asked the
/// user (a confirmation sheet): nothing here is reachable without one.
@MainActor
struct NoteDeleter {
    enum Failure: Error, Equatable {
        /// The owner is off, failed or not answering: nothing was deleted.
        case sourceUnavailable
        /// The owner refused or failed: nothing was deleted, the overlays are untouched.
        case sourceFailed
        /// The owner deleted the note but the copy in Notes could not be removed (the next sweep detaches it).
        case overlaysNotRemoved
    }

    let library: NoteLibrary
    let store: NotesStore
    let registry: NoteDocumentRegistry

    func delete(_ item: NoteItemID) async throws {
        switch item {
        case .live(let key) where key.pluginID == NotesStore.manualPluginID:
            try removeOverlays(of: item) { try store.deleteLiveOverlays(of: key) }
        case .live(let key):
            guard let source = await library.source(for: key) else { throw Failure.sourceUnavailable }
            do {
                try await source.delete(key)
            } catch {
                throw Failure.sourceFailed
            }
            try removeOverlays(of: item) { try store.deleteLiveOverlays(of: key) }
        case .detached(let key, let started):
            try removeOverlays(of: item) { try store.deleteDetachedOverlays(key: key, startedAtMs: started) }
        }
    }

    private func removeOverlays(of item: NoteItemID, _ delete: () throws -> Int) throws {
        // The text typed into an open document goes with the note the user confirmed deleting.
        registry.discard(item: item)
        do { _ = try delete() } catch { throw Failure.overlaysNotRemoved }
    }
}
