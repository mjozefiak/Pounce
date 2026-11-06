import CryptoKit
import Foundation
import LintelCore

/// Where a comment points, as `note_comment` stores it (spec "Data Model"): UTF-16 offsets into the revision the
/// comment was made on, the quoted text, 32 characters of context on each side and the hash of the blocks the range
/// touched. Offsets are only a hint: the quote is what finds the text again after edits (`AnchorResolver`).
struct CommentAnchor: Equatable, Sendable {
    var start: Int
    var end: Int
    /// SHA-256 (hex) of the joined text of the blocks the range touches, at comment time.
    var blockHash: String
    /// The commented text. Note text: never logged.
    var quote: String
    var prefix: String
    var suffix: String
}

/// Builds anchors from a selection. Pure.
enum CommentAnchors {
    /// Characters of context kept on each side of the quote.
    static let contextLength = 32
    /// The longest passage one comment may point at; a longer selection is refused instead of cut.
    static let maxQuoteLength = 2000

    /// The anchor for `range` (UTF-16) of `text`, or `nil` when the range is outside the text, blank, or longer than
    /// `maxQuoteLength`.
    static func make(in text: String, range: NSRange) -> CommentAnchor? {
        let source = text as NSString
        guard range.location != NSNotFound, range.length > 0, range.length <= maxQuoteLength,
            range.location >= 0, range.location + range.length <= source.length
        else { return nil }
        let quote = source.substring(with: range)
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return CommentAnchor(
            start: range.location, end: range.location + range.length, blockHash: blockHash(in: text, range: range),
            quote: quote, prefix: context(before: range.location, in: source),
            suffix: context(after: range.location + range.length, in: source))
    }

    /// The hash of the blocks the range touches, joined with a blank line. A range inside a gap touches none.
    static func blockHash(in text: String, range: NSRange) -> String {
        let blocks = MarkdownBlocks.split(text)
        let located = BlockLocator.ranges(of: blocks, in: text)
        var touched: [String] = []
        for (block, found) in zip(blocks, located) {
            guard let found, NSIntersectionRange(found, range).length > 0 else { continue }
            touched.append(block)
        }
        return hash(touched.joined(separator: "\n\n"))
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func context(before location: Int, in source: NSString) -> String {
        guard location > 0 else { return "" }
        var start = max(0, location - contextLength)
        if start > 0 { start = source.rangeOfComposedCharacterSequence(at: start).location }
        return source.substring(with: NSRange(location: start, length: location - start))
    }

    private static func context(after location: Int, in source: NSString) -> String {
        guard location < source.length else { return "" }
        var end = min(source.length, location + contextLength)
        if end < source.length {
            let sequence = source.rangeOfComposedCharacterSequence(at: end - 1)
            end = sequence.location + sequence.length
        }
        return source.substring(with: NSRange(location: location, length: end - location))
    }
}

/// Where the quote is now.
enum AnchorResolution: Equatable, Sendable {
    /// The quoted text, at this range of the text that was searched.
    case found(NSRange)
    /// The quote is no longer in the text: shown as "text changed" until it is resolved or re-anchored.
    case changed

    var range: NSRange? {
        if case .found(let range) = self { range } else { nil }
    }
}

/// Re-anchoring (spec "Data Model", `note_comment`): finds `anchor_quote` in the text; when several matches exist
/// it picks the one whose neighbours best match the stored prefix and suffix, then the one nearest the original
/// offset. No match leaves the comment visible as "text changed". Pure, so an edit before the quote only moves it.
enum AnchorResolver {
    /// A quote that matches more often than this is not searched further (a one-letter quote in a long note).
    static let matchLimit = 5000

    static func resolve(_ anchor: CommentAnchor, in text: String) -> AnchorResolution {
        let source = text as NSString
        let quote = anchor.quote as NSString
        guard quote.length > 0, quote.length <= source.length else { return .changed }
        var matches: [NSRange] = []
        var from = 0
        while from + quote.length <= source.length, matches.count < matchLimit {
            let found = source.range(
                of: anchor.quote, options: [.literal], range: NSRange(location: from, length: source.length - from))
            if found.location == NSNotFound { break }
            matches.append(found)
            from = found.location + 1
        }
        guard let first = matches.first else { return .changed }
        if matches.count == 1 { return .found(first) }
        let best = matches.min { lhs, rhs in
            let a = score(lhs, anchor: anchor, in: source)
            let b = score(rhs, anchor: anchor, in: source)
            if a != b { return a > b }
            let distanceA = abs(lhs.location - anchor.start)
            let distanceB = abs(rhs.location - anchor.start)
            return distanceA == distanceB ? lhs.location < rhs.location : distanceA < distanceB
        }
        return .found(best ?? first)
    }

    /// How many characters of the stored context the text around `range` still shares.
    private static func score(_ range: NSRange, anchor: CommentAnchor, in source: NSString) -> Int {
        let beforeStart = max(0, range.location - anchor.prefix.utf16.count)
        let before = source.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
        let afterStart = range.location + range.length
        let after = source.substring(
            with: NSRange(location: afterStart, length: min(anchor.suffix.utf16.count, source.length - afterStart)))
        let prefix = zip(before.reversed(), anchor.prefix.reversed()).prefix { $0 == $1 }.count
        let suffix = zip(after, anchor.suffix).prefix { $0 == $1 }.count
        return prefix + suffix
    }
}
