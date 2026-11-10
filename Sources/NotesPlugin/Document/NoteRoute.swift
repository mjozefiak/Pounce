import Foundation
import LintelKit

/// The `WorkspaceRoute` that asks the Notes section to show a note: kind `openNote`, id the note key's raw value
/// (`meetings:<uuid>`, `dictation:<store id>/<row id>`, `notes:<uuid>`). A route names a live note; a detached
/// overlay is reached from the explorer only.
enum NoteRoute {
    static let kind = "openNote"

    static func route(for key: NoteKey) -> WorkspaceRoute {
        WorkspaceRoute(kind: kind, id: key.rawValue)
    }

    /// The note a route points at, `nil` for another kind or an id that is not `<plugin id>:<id>`.
    static func itemID(for route: WorkspaceRoute) -> NoteItemID? {
        guard route.kind == kind, let separator = route.id.firstIndex(of: ":"), separator != route.id.startIndex,
            route.id.index(after: separator) != route.id.endIndex
        else { return nil }
        return .live(
            NoteKey(
                pluginID: PluginID(rawValue: String(route.id[..<separator])),
                id: String(route.id[route.id.index(after: separator)...])))
    }
}
