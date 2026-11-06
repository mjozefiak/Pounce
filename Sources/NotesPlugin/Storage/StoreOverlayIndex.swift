import Foundation
import LintelKit

/// The library's overlay ports over the real store. Read-only except `detach`, which is the one detach
/// primitive (step 4.2 wraps it with the registry's flush and re-key). Not wired into the plugin before 4.2.
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
