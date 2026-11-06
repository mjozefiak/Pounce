import Foundation
import LintelKit

/// The library's read ports over the real store (and the bare detach primitive; the plugin detaches through
/// `RegistryOverlayDetacher`, which flushes and re-keys the open documents first).
struct StoreOverlayIndex: OverlayIndex, OverlayDetacher {
    let store: NotesStore

    func overlays(for keys: [NoteKey]) async throws -> [OverlayRecord] { try store.liveOverlays(for: keys) }
    func manualNotes() async throws -> [OverlayRecord] { try store.manualOverlays() }
    func detachedOverlays() async throws -> [OverlayRecord] { try store.detachedOverlays() }
    func keptOverlays(excludingPlugins excluding: Set<PluginID>) async throws -> [OverlayRecord] {
        try store.keptOverlays(excludingPlugins: excluding)
    }
    func liveOverlayKeys() async throws -> [NoteKey] { try store.liveOverlayKeys() }
    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws {
        try store.detach(key)
    }
}

/// The overlay ports over the store that opens on first need. A store that cannot be read (Keychain locked or
/// denied, failed open) throws, so the library lists the sources without overlays and says so; a detach goes
/// through the registry (`RegistryOverlayDetacher`).
struct LazyStoreOverlays: OverlayIndex, OverlayDetacher {
    let store: @MainActor @Sendable () -> NotesStore?
    let registry: NoteDocumentRegistry

    private func opened() async throws -> NotesStore {
        guard let store = await store() else { throw NotesError.keyUnavailable }
        return store
    }

    func overlays(for keys: [NoteKey]) async throws -> [OverlayRecord] {
        try await StoreOverlayIndex(store: opened()).overlays(for: keys)
    }
    func manualNotes() async throws -> [OverlayRecord] { try await StoreOverlayIndex(store: opened()).manualNotes() }
    func detachedOverlays() async throws -> [OverlayRecord] {
        try await StoreOverlayIndex(store: opened()).detachedOverlays()
    }
    func keptOverlays(excludingPlugins excluding: Set<PluginID>) async throws -> [OverlayRecord] {
        try await StoreOverlayIndex(store: opened()).keptOverlays(excludingPlugins: excluding)
    }
    func liveOverlayKeys() async throws -> [NoteKey] { try await StoreOverlayIndex(store: opened()).liveOverlayKeys() }
    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws {
        try await RegistryOverlayDetacher(store: opened(), registry: registry).detach(key, reason: reason)
    }
}
