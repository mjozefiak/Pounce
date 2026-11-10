import Foundation
import LintelKit

/// The badge an explorer row carries: the source's state, or a fact Notes adds.
enum NoteBadge: Sendable, Equatable {
    case recording
    case processing
    case writing(done: Int, of: Int)
    case partial
    case stale
    case interrupted
    case failed
    case needsModel
    /// A kept overlay whose recording is gone.
    case recordingRemoved
    /// A kept overlay whose source plugin is off, failed or did not answer; the row is read-only.
    case sourceOff(PluginID)

    /// `nil` for `ready`: a finished note has no badge.
    init?(state: NoteState) {
        switch state {
        case .ready: return nil
        case .recording: self = .recording
        case .processing: self = .processing
        case .writing(let done, let total): self = .writing(done: done, of: total)
        case .partial: self = .partial
        case .stale: self = .stale
        case .interrupted: self = .interrupted
        case .failed: self = .failed
        case .needsModel: self = .needsModel
        }
    }
}

/// One row of the explorer.
struct NoteRow: Identifiable, Sendable, Equatable {
    var id: NoteItemID
    var summary: NoteSummary
    var badge: NoteBadge?
    /// The overlaid layers of this note (what the user edited or commented); empty for an unedited recording.
    var overlays: [OverlayRecord]
    /// A kept overlay of a source that is off: shown, never edited or merged into a source row.
    var isReadOnly: Bool

    var pluginID: PluginID { id.key.pluginID }
    var startedAt: Date { summary.startedAt }
}

/// Where a row sorts: newest first, ties by identity.
struct NoteSortPosition: Sendable, Equatable {
    var date: Date
    var tie: String

    init(date: Date, tie: String) {
        self.date = date
        self.tie = tie
    }

    init(_ row: NoteRow) {
        self.init(date: row.startedAt, tie: row.id.sortKey)
    }

    /// True when `self` comes earlier in the list than `other`.
    func isBefore(_ other: NoteSortPosition) -> Bool {
        date != other.date ? date > other.date : tie < other.tie
    }
}
