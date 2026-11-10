import LintelUI
import SwiftUI

/// The length of a comment against `NotesStore.commentLimit`, shown from 90 % of the limit and in the error colour
/// above it, where the send button is off. A comment is never cut: the user shortens it.
struct CommentLengthHint: View {
    let text: String
    @Environment(\.lintelTextSize) private var textSize

    /// From where the count is shown.
    static let showFrom = NotesStore.commentLimit / 10 * 9

    static func length(of text: String) -> Int { NotesStore.commentLength(of: text) }
    static func isTooLong(_ text: String) -> Bool { length(of: text) > NotesStore.commentLimit }

    var body: some View {
        let length = Self.length(of: text)
        if length >= Self.showFrom {
            Text(
                "Length \(length) of \(NotesStore.commentLimit)",
                comment: "Comment field: how many characters the comment has and the most it may have"
            )
            .font(textSize.font(.footnote))
            .foregroundStyle(length > NotesStore.commentLimit ? LintelBrand.statusError : LintelBrand.secondaryText)
            .accessibilityLabel(
                Text(
                    "Length \(length) of \(NotesStore.commentLimit)",
                    comment: "Comment field: how many characters the comment has and the most it may have"))
        }
    }
}
