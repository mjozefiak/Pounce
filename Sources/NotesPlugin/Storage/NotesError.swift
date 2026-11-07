import Foundation
import LintelKit

/// What can go wrong in the Notes store and its callers, with stable codes for the log (spec "NotesPlugin" and
/// "Diagnostics"). Errors carry codes and plugin ids only, never note text or titles.
enum NotesError: Error, Equatable, Sendable {
    /// The Keychain key could not be read or created.
    case keyUnavailable
    /// `notes.sqlite` was written by a newer Lintel: Notes is read-only and migrates nothing.
    case schemaNewer
    /// The hidden `plugins.notes.readOnly` setting is on: nothing is written.
    case readOnly
    case casConflict
    case guardRejected(rule: String)
    case lockTimeout
    case sourceUnavailable(pluginID: PluginID)
    case migrationFailed(step: String)
    /// The store was closed while background work still used it.
    case storeClosed

    /// The stable code written to the log; never changes after release.
    var code: String {
        switch self {
        case .keyUnavailable: "keyUnavailable"
        case .schemaNewer: "schemaNewer"
        case .readOnly: "readOnly"
        case .casConflict: "casConflict"
        case .guardRejected(let rule): "guardRejected(\(rule))"
        case .lockTimeout: "lockTimeout"
        case .sourceUnavailable(let pluginID): "sourceUnavailable(\(pluginID.rawValue))"
        case .migrationFailed(let step): "migrationFailed(\(step))"
        case .storeClosed: "storeClosed"
        }
    }
}
