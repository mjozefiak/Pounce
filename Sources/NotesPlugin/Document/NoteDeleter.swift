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
        /// A manual note or a copy of a removed recording could not be deleted: there is no owner, nothing was
        /// deleted and the text still being typed is kept.
        case copyNotDeleted
    }

    let library: NoteLibrary
    let store: NotesStore
    let registry: NoteDocumentRegistry

    func delete(_ item: NoteItemID) async throws {
        switch item {
        case .live(let key) where key.pluginID == NotesStore.manualPluginID:
            try removeOverlays(of: item, ownerDeleted: false) { try store.deleteLiveOverlays(of: key) }
        case .live(let key):
            guard let source = await library.source(for: key) else { throw Failure.sourceUnavailable }
            do {
                try await source.delete(key)
            } catch {
                throw Failure.sourceFailed
            }
            try removeOverlays(of: item, ownerDeleted: true) { try store.deleteLiveOverlays(of: key) }
        case .detached(let key, let started):
            try removeOverlays(of: item, ownerDeleted: false) { try store.deleteDetachedOverlays(key: key, startedAtMs: started) }
        }
    }

    private func removeOverlays(of item: NoteItemID, ownerDeleted: Bool, _ delete: () throws -> Int) throws {
        do { _ = try delete() } catch { throw ownerDeleted ? Failure.overlaysNotRemoved : Failure.copyNotDeleted }
        // The text typed into an open document goes with the note the user confirmed deleting, but only once the
        // rows are gone: a failed delete keeps the buffer (never lose user-written text).
        registry.discard(item: item)
    }
}
