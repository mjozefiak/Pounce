import Foundation
import LintelKit

/// "N copies in Notes are kept" and "Also delete kept copies" (owner decision L1-39), answered for the source
/// plugins through the shell (`PluginContext.keptNoteCopies` / `deleteKeptNoteCopies`).
///
/// Copies are removed ONLY when the user ticked the box, and only after the owner's own deletion succeeded. The
/// count never opens a store that does not exist: no Keychain item and no `notes.sqlite` appear because a user
/// looked at a confirmation sheet.
extension NotesPlugin {
    /// The plugins whose recordings Notes keeps copies of. Any other feature's Erase Data sheet asks too and gets
    /// 0 without Notes touching its library or the Keychain.
    private static let ownersWithCopies: Set<PluginID> = ["meetings", "dictation"]

    /// The store, when the user has one (or it is already open); `nil` when Notes never created it or its key
    /// cannot be read. Counting or removing never resets or archives the library.
    private func existingStore(for owner: PluginID) -> NotesStore? {
        guard owner != NotesStore.manualPluginID, Self.ownersWithCopies.contains(owner) else { return nil }
        return library.openIfKeyPresent()
    }

    public func keptNoteCopyCount(ofOwner owner: PluginID) async -> Int {
        guard let store = existingStore(for: owner) else { return 0 }
        return (try? store.keptCopyCount(owner: owner)) ?? 0
    }

    public func deleteKeptNoteCopies(ofOwner owner: PluginID, ownerErased: Bool) async -> Bool {
        guard let store = existingStore(for: owner) else { return true }
        let storeProvider = storeProvider
        let registry = documents
        let overlays = LazyStoreOverlays(store: storeProvider, registry: registry)
        var undecided = false
        if !ownerErased {
            // Clear and Delete leave the owner running: ask it which recordings are gone, so their copies detach.
            let library = NoteLibrary(sources: noteSourceProvider, overlays: overlays, detacher: overlays)
            let reconciler = SourceReconciler(
                store: store, library: library, detacher: overlays, registry: registry, clock: context.clock)
            _ = await reconciler.sweep()
            undecided = await library.undecidedOwners.contains(owner)
        }
        do {
            let ids = try store.overlayIDs(ofOwner: owner, detachedOnly: !ownerErased)
            await registry.discard(docIDs: Set(ids))
            try store.deleteDocuments(ids)
            // An owner that could not say which recordings are gone leaves the copies the count promised: say so
            // instead of "removed".
            if undecided, try store.keptCopyCount(owner: owner) > 0 { return false }
            return true
        } catch {
            return false
        }
    }
}
