import Foundation
import LintelKit

/// Which of the explorer's two lists a note belongs to (owner decision 2026-11-07, ADR 0008 deviation 14):
/// dictations are not mixed with meetings and manual notes. A dictation is whatever a `dictation` source owns or a
/// note of kind `NoteKind.dictation`; everything else is a note. Classification only reads the key and the kind
/// that the contract already carries, so no plugin is imported and the contract is untouched.
enum NoteCollection: String, Sendable, CaseIterable, Equatable {
    case notes
    case dictations

    /// The plugin whose recordings are dictations.
    static let dictationPlugin: PluginID = "dictation"

    static func of(key: NoteKey, kind: NoteKind? = nil) -> NoteCollection {
        kind == .dictation || key.pluginID == dictationPlugin ? .dictations : .notes
    }

    static func of(_ id: NoteItemID) -> NoteCollection { of(key: id.key) }

    static func of(_ row: NoteRow) -> NoteCollection { of(key: row.id.key, kind: row.summary.kind) }

    /// Whether the source with this plugin id is listed in this collection.
    func includesSource(_ id: PluginID) -> Bool { NoteCollection.of(key: NoteKey(pluginID: id, id: "-")) == self }
}
