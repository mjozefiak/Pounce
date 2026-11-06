import Foundation
import LintelKit

/// What names one note in the explorer, a tab, a route or a delete (spec "Data Model", Identity). A live note is
/// its key; a detached overlay (its recording is gone, or was recreated under the same key) is the key plus the
/// start time of the recording it was written against, so the old and the new note never share an identity.
enum NoteItemID: Hashable, Sendable {
    case live(NoteKey)
    case detached(NoteKey, startedAtMs: Int64)

    var key: NoteKey {
        switch self {
        case .live(let key), .detached(let key, _): key
        }
    }

    /// A stable text used only to order rows that start at the same moment.
    var sortKey: String {
        switch self {
        case .live(let key): key.rawValue
        case .detached(let key, let started): "\(key.rawValue)#\(started)"
        }
    }
}

/// The way Notes rounds a start time to compare it with `note_doc.source_started_at_ms`.
enum NoteTime {
    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }
}
