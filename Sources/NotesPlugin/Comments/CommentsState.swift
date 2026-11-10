import Foundation

/// What the store holds for the comments of one layer document. Comment text is other people's words: kept in
/// memory for the inspector, never logged.
struct CommentsSnapshot: Sendable, Equatable {
    var docID: Int64
    var layer: String
    var threads: [CommentThread]
    /// The text of the head revision, for finding the quotes when the editor is not open.
    var headBody: String
    /// A detached overlay (its recording is gone) shows its comments but nothing is written to them.
    var isDetached: Bool
}

/// The inspector's Comments for the layer on screen.
enum CommentsState: Equatable {
    /// Not read yet.
    case idle
    case loading
    /// The layer has no overlay: nothing was commented.
    case none
    case loaded(CommentsSnapshot)
    case failed
}

/// The two chips above the threads (prototype `.chip3`).
enum CommentFilter: Equatable, Sendable {
    case open
    case resolved
}

/// A comment's highlight in the editor: where its quote is now, and whether it is the selected thread.
struct CommentHighlight: Equatable, Sendable {
    var threadID: Int64
    var range: NSRange
    var isSelected: Bool
}
