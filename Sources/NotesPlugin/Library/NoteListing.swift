import Foundation
import LintelKit

/// A source that gave no answer for a listing. It is "unknown", never "gone": its notes are not shown for now
/// and nothing about it is detached.
struct UnavailableSource: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        case timedOut
        case failed
    }

    var pluginID: PluginID
    var reason: Reason
}

/// What a source has handed over and not yet been shown: the library merges several newest-first streams, so a
/// page can stop in the middle of one source's page.
struct SourceProgress: Sendable {
    struct Item: Sendable {
        var summary: NoteSummary
        var overlays: [OverlayRecord]
    }

    var next: NoteCursor?
    var exhausted = false
    var total = 0
    var buffer: [Item] = []
}

/// The position after a page. Opaque to callers; valid only while the set of sources is the one it was made
/// for (a changed set starts the listing over, see `NoteListing.restarted`).
struct NoteListCursor: Sendable {
    var generation: Int
    var boundary: NoteSortPosition?
    var sources: [PluginID: SourceProgress]
}

struct NoteListing: Sendable {
    var rows: [NoteRow]
    /// `nil` when nothing more can be listed.
    var next: NoteListCursor?
    /// Rows known across the sources and Notes' own rows.
    var total: Int
    var unavailable: [UnavailableSource]
    /// `false` when `notes.sqlite` could not be read: sources are listed without overlays.
    var overlaysAvailable: Bool
    /// The set of sources changed since the cursor was made, so this page is the first one again.
    var restarted: Bool
}
