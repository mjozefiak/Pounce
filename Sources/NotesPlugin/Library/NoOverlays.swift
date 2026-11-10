import Foundation
import LintelKit

/// The overlay ports until the store exists (step 4.0): no note has an overlay, there are no manual notes and
/// nothing is detached. The workspace lists the sources' notes exactly as they are.
struct NoOverlays: OverlayIndex, OverlayDetacher {
    func overlays(for keys: [NoteKey]) async throws -> [OverlayRecord] { [] }
    func manualNotes() async throws -> [OverlayRecord] { [] }
    func detachedOverlays() async throws -> [OverlayRecord] { [] }
    func keptOverlays(excludingPlugins excluding: Set<PluginID>) async throws -> [OverlayRecord] { [] }
    func liveOverlayKeys() async throws -> [NoteKey] { [] }
    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws {}
}
