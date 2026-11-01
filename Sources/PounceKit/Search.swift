import Foundation

/// The user's query after normalisation by `PounceCore` (lowercase, NFD, diacritics folded).
public struct NormalizedQuery: Hashable, Sendable {
    /// Exactly what the user typed.
    public let raw: String
    /// The normalised form every source matches against.
    public let normalized: String

    public init(raw: String, normalized: String) {
        self.raw = raw
        self.normalized = normalized
    }

    public var isEmpty: Bool { normalized.isEmpty }
}

/// How a candidate matched the query. Tiers are ordered best first; frecency never moves a candidate
/// to a better tier.
public enum MatchTier: Int, Comparable, Sendable, CaseIterable {
    case exact = 0
    case prefix = 1
    case wordStart = 2
    case substring = 3
    case fuzzy = 4

    /// A better tier compares as smaller, so sorting ascending puts the best tier first.
    public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Result of matching one candidate title against a query.
public struct MatchResult: Hashable, Sendable {
    public let tier: MatchTier
    /// Score within the tier; higher is better.
    public let score: Double
    /// Matched character ranges in the candidate title, as `Character` offsets, for highlighting.
    public let highlightRanges: [Range<Int>]

    public init(tier: MatchTier, score: Double, highlightRanges: [Range<Int>] = []) {
        self.tier = tier
        self.score = score
        self.highlightRanges = highlightRanges
    }
}

/// Where a result row takes its icon from.
public enum IconRef: Hashable, Sendable {
    /// The icon of a file or bundle on disk.
    case file(URL)
    /// The icon of an installed application.
    case bundleIdentifier(String)
    /// An SF Symbol name.
    case symbol(String)
}

/// One result row produced by a search source.
public struct Candidate: Hashable, Sendable {
    public let itemKey: ItemKey
    public let title: String
    public let subtitle: String?
    public let icon: IconRef
    public let match: MatchResult
    /// Source signal applied within the tier (for example depth penalty or recent mtime).
    public let boost: Double

    public init(
        itemKey: ItemKey,
        title: String,
        subtitle: String? = nil,
        icon: IconRef,
        match: MatchResult,
        boost: Double = 0
    ) {
        self.itemKey = itemKey
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.match = match
        self.boost = boost
    }
}

/// A source of search results contributed by a plugin.
///
/// `search` runs off the main actor, must react to `Task` cancellation, and reports failures by
/// throwing. The host gives every source its own time budget; a source that throws or overruns only
/// loses its own section.
public protocol SearchSource: Sendable {
    var id: SourceID { get }

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate]

    /// Actions for a candidate: the first one runs on Return, the second on Command-Return.
    func actions(for candidate: Candidate) -> [ResultAction]
}

extension SearchSource {
    public func actions(for candidate: Candidate) -> [ResultAction] { [] }
}
