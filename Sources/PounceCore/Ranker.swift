import Foundation
import PounceKit

/// Orders the candidates of one result section. It never reads a database: usage statistics come in as
/// an argument.
///
/// Order: match tier first (frecency never moves a candidate to a better tier), then, within the tier,
/// the sum of the match score, decayed frecency, the query-association bonus and the source's `boost`.
public struct Ranker: Sendable {
    /// Frecency halves every seven days (spec: Zapytanie i ranking). `UsageRepository` uses the same value
    /// when it accumulates uses.
    public static let frecencyHalfLife: TimeInterval = 7 * 24 * 60 * 60
    /// Query prefixes are stored and looked up with 1 to 4 normalised characters.
    public static let maximumQueryPrefixLength = 4

    public let now: Date

    public init(now: Date) {
        self.now = now
    }

    /// The prefix under which a query is associated with the chosen item, or `nil` for an empty query.
    public static func queryPrefix(_ normalizedQuery: String) -> String? {
        guard !normalizedQuery.isEmpty else { return nil }
        return String(normalizedQuery.prefix(maximumQueryPrefixLength))
    }

    /// Frecency decayed from the last use to `now`.
    public func decayedFrecency(_ stats: UsageStats) -> Double {
        guard let lastUsedAt = stats.lastUsedAt else { return stats.frecency }
        let elapsed = max(0, now.timeIntervalSince(lastUsedAt))
        return stats.frecency * pow(2, -elapsed / Self.frecencyHalfLife)
    }

    /// The within-tier score of one candidate.
    public func score(_ candidate: Candidate, stats: UsageStats?) -> Double {
        var total = candidate.match.score + candidate.boost
        if let stats {
            total += log2(1 + decayedFrecency(stats))
            total += 0.5 * log2(1 + Double(stats.queryAssociationCount))
        }
        return total
    }

    /// Sorts one section: tier, then score, then title and key so equal candidates keep a stable order.
    public func rank(_ candidates: [Candidate], stats: [ItemKey: UsageStats]) -> [Candidate] {
        let scored = candidates.map { ($0, score($0, stats: stats[$0.itemKey])) }
        return scored.sorted { lhs, rhs in
            if lhs.0.match.tier != rhs.0.match.tier {
                return lhs.0.match.tier < rhs.0.match.tier
            }
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return Self.tieBreak(lhs.0, rhs.0)
        }
        .map(\.0)
    }

    /// The most-used candidates for an empty query: only items with recorded uses, by decayed frecency.
    public func recent(_ candidates: [Candidate], stats: [ItemKey: UsageStats], limit: Int) -> [Candidate] {
        let used = candidates.compactMap { candidate -> (Candidate, Double)? in
            guard let stats = stats[candidate.itemKey], stats.useCount > 0 else { return nil }
            return (candidate, decayedFrecency(stats))
        }
        return used.sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : Self.tieBreak(lhs.0, rhs.0)
        }
        .prefix(limit)
        .map(\.0)
    }

    private static func tieBreak(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        let order = lhs.title.localizedStandardCompare(rhs.title)
        if order != .orderedSame {
            return order == .orderedAscending
        }
        return lhs.itemKey.rawValue < rhs.itemKey.rawValue
    }
}
