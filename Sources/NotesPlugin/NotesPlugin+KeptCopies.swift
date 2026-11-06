import Foundation
import LintelKit

/// "N copies in Notes are kept" and "Also delete kept copies" (owner decision L1-39), answered for the source
/// plugins through the shell (`PluginContext.keptNoteCopies` / `deleteKeptNoteCopies`).
///
/// Copies are removed ONLY when the user ticked the box, and only after the owner's own deletion succeeded. The
/// count never opens a store that does not exist: no Keychain item and no `notes.sqlite` appear because a user
/// looked at a confirmation sheet.
extension NotesPlugin {
    /// The store, when the user has one (or it is already open); `nil` when Notes never created it.
    private func existingStore() -> NotesStore? {
        if library.store == nil {
            guard library.storeFileExists else { return nil }
            library.open()
        }
        return library.store
    }

    public func keptNoteCopyCount(ofOwner owner: PluginID) async -> Int {
        guard owner != NotesStore.manualPluginID, let store = existingStore() else { return 0 }
        return (try? store.keptCopyCount(owner: owner)) ?? 0
    }

    public func deleteKeptNoteCopies(ofOwner owner: PluginID, ownerErased: Bool) async -> Bool {
        guard owner != NotesStore.manualPluginID, let store = existingStore() else { return true }
        let storeProvider = storeProvider
        let registry = documents
        let overlays = LazyStoreOverlays(store: storeProvider, registry: registry)
        if !ownerErased {
            // Clear and Delete leave the owner running: ask it which recordings are gone, so their copies detach.
            let library = NoteLibrary(sources: noteSourceProvider, overlays: overlays, detacher: overlays)
            let reconciler = SourceReconciler(
                store: store, library: library, detacher: overlays, registry: registry, clock: context.clock)
            _ = await reconciler.sweep()
        }
        do {
            let ids = try store.overlayIDs(ofOwner: owner, detachedOnly: !ownerErased)
            await registry.discard(docIDs: Set(ids))
            try store.deleteDocuments(ids)
            return true
        } catch {
            return false
        }
    }
}
