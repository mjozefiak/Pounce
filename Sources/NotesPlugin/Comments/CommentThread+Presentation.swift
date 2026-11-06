import Foundation
import LintelKit

/// How a thread is read out and shortened for the screen. Pure.
extension CommentThread {
    /// The longest quote the card and VoiceOver show; the rest is cut with an ellipsis.
    static let quoteDisplayLimit = 80

    /// The quote on one line, cut at `quoteDisplayLimit`.
    var displayQuote: String {
        let flat = anchor.quote.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        let trimmed = flat.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > Self.quoteDisplayLimit else { return trimmed }
        return String(trimmed.prefix(Self.quoteDisplayLimit)) + "…"
    }

    /// What VoiceOver announces for the thread: it names the quote, so the thread is found without reading the
    /// note. The comments, replies and buttons inside are read after it.
    func spokenTitle(textChanged: Bool) -> String {
        let quote = displayQuote
        let base =
            isOpen
            ? String(
                localized: "Comment on “\(quote)”",
                comment: "Accessibility label of an open comment thread, naming the commented text")
            : String(
                localized: "Resolved comment on “\(quote)”",
                comment: "Accessibility label of a resolved comment thread, naming the commented text")
        guard textChanged else { return base }
        return base
            + ". "
            + String(
                localized: "The text changed.",
                comment: "Accessibility: the commented text is no longer in the note")
    }

    /// Who wrote a comment: "You", "AI", or the stored name of any other author.
    static func authorName(_ author: String) -> String {
        switch NoteAuthor(rawValue: author) {
        case .human:
            String(localized: "comment.author.you", defaultValue: "You", comment: "Comments: the user's own comment")
        case .agent:
            String(
                localized: "comment.author.ai", defaultValue: "AI", comment: "Comments: a comment written by the agent")
        default: author
        }
    }

    /// Author and time of one comment, read as words ("You, today 14:58").
    static func spokenMeta(author: String, when: String) -> String {
        "\(authorName(author)), \(when)"
    }
}
