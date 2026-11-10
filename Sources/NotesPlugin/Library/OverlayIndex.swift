import Foundation
import LintelKit

/// One row of `note_doc` as the library reads it: an overlaid layer of a recorded note, or a manual note.
/// Metadata only, never text. The store that fills it comes with step 4.0; until then a port stands in for it.
struct OverlayRecord: Sendable, Equatable {
    var docID: Int64
    var key: NoteKey
    var layer: String
    var kind: NoteKind
    var sourcePluginID: PluginID
    /// `title_override`, manual notes only.
    var title: String?
    /// `source_started_at_ms`: the start of the recording the overlay was written against (nil for manual notes).
    var startedAtMs: Int64?
    var createdAt: Date
    var updatedAt: Date
    /// User writing or an open comment: the overlay is never deleted with its source.
    var isKept: Bool

    init(
        docID: Int64, key: NoteKey, layer: String, kind: NoteKind, sourcePluginID: PluginID, title: String? = nil,
        startedAtMs: Int64? = nil, createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date = Date(timeIntervalSince1970: 0), isKept: Bool = false
    ) {
        self.docID = docID
        self.key = key
        self.layer = layer
        self.kind = kind
        self.sourcePluginID = sourcePluginID
        self.title = title
        self.startedAtMs = startedAtMs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isKept = isKept
    }
}

/// What the library reads from `notes.sqlite`. Read-only; a throw means the store cannot be read (the library
/// then lists the sources without overlays and says so).
protocol OverlayIndex: Sendable {
    /// The live (`present`) overlay rows of these keys.
    func overlays(for keys: [NoteKey]) async throws -> [OverlayRecord]
    /// Manual notes (`source_plugin_id` is `notes`).
    func manualNotes() async throws -> [OverlayRecord]
    /// Overlays whose recording is gone or was recreated (`detached`).
    func detachedOverlays() async throws -> [OverlayRecord]
    /// Live, kept overlays of recorded notes whose source plugin is not in `excluding` (the plugin is off,
    /// failed or did not answer).
    func keptOverlays(excludingPlugins excluding: Set<PluginID>) async throws -> [OverlayRecord]
    /// Every key that has a live overlay of a recorded note, for the detach sweep.
    func liveOverlayKeys() async throws -> [NoteKey]
}

enum OverlayDetachReason: Sendable, Equatable {
    /// The source reports another start time for this key than the overlay was written against.
    case startedAtChanged(sourceStartedAtMs: Int64)
    /// The sweep asked the source and it does not know the key (its store was open).
    case sourceGone
}

/// The one place that detaches an overlay (merge, open and sweep, spec "Data Model"): it flushes and re-keys an
/// open document, then moves every live row of the key to `detached` in one transaction (step 4.2). The library
/// only calls it and never writes.
protocol OverlayDetacher: Sendable {
    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws
}
