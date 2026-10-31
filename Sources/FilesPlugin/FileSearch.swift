import Foundation
import PounceCore
import PounceKit

/// One file search result before it becomes a `Candidate`.
struct FileHit: Sendable {
    let node: Int32
    let path: String
    let name: String
    let kind: EntryKind
    let match: MatchResult
    let boost: Double
}

/// Parallel top-N search over an index snapshot (spec step 3.2).
///
/// The node table is split into chunks searched in a `TaskGroup`; each chunk checks
/// `Task.checkCancellation()` every 10 000 nodes. A cheap byte-level pass over the normalised names
/// decides the tier and an approximate score for every node; only the best `2 × limit` go through
/// `FuzzyMatcher` for the exact score and highlight ranges. Within a tier the `boost` lowers deep paths
/// and raises recently modified items.
enum FileSearch {
    static let cancellationInterval = 10_000
    static let minimumChunk = 16_384

    struct Scored: Sendable {
        let node: Int32
        let tier: MatchTier
        let score: Double
    }

    static func search(
        _ query: NormalizedQuery,
        in store: NameStore,
        limit: Int,
        now: Date = Date(),
        chunks: Int = ProcessInfo.processInfo.activeProcessorCount
    ) async throws -> [FileHit] {
        let needle = Array(query.normalized.utf8)
        guard !needle.isEmpty, limit > 0, store.nodeCount > 0 else { return [] }
        let keep = limit * 2
        let nowSeconds = now.timeIntervalSince1970
        let count = store.nodeCount
        let chunkSize = max(minimumChunk, (count + max(1, chunks) - 1) / max(1, chunks))

        let best = try await withThrowingTaskGroup(of: [Scored].self) { group in
            var start = 0
            while start < count {
                let range = start..<min(start + chunkSize, count)
                group.addTask {
                    try scan(range, needle: needle, store: store, keep: keep, now: nowSeconds)
                }
                start += chunkSize
            }
            var merged: [Scored] = []
            for try await part in group {
                merged.append(contentsOf: part)
            }
            return merged
        }
        try Task.checkCancellation()

        let scalars = Array(query.normalized.unicodeScalars)
        var hits: [FileHit] = []
        for scored in best.sorted(by: isBetter).prefix(keep) {
            let node = scored.node
            let name = store.name(node)
            // The exact matcher decides the final tier, score and highlight; the byte pass only chose
            // which nodes are worth it.
            guard let match = FuzzyMatcher.match(scalars, in: NormalizedText(name)) else { continue }
            hits.append(
                FileHit(
                    node: node, path: store.path(node), name: name, kind: store.kind(node), match: match,
                    boost: boost(node, store: store, now: nowSeconds)))
        }
        hits.sort { lhs, rhs in
            if lhs.match.tier != rhs.match.tier { return lhs.match.tier < rhs.match.tier }
            let left = lhs.match.score + lhs.boost
            let right = rhs.match.score + rhs.boost
            if left != right { return left > right }
            return lhs.path < rhs.path
        }
        return Array(hits.prefix(limit))
    }

    static func isBetter(_ lhs: Scored, _ rhs: Scored) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        return lhs.node < rhs.node
    }

    /// Searches one chunk and keeps its best `keep` nodes.
    static func scan(
        _ range: Range<Int>, needle: [UInt8], store: NameStore, keep: Int, now: TimeInterval
    ) throws -> [Scored] {
        var top = TopList(capacity: keep)
        var sinceCheck = 0
        for index in range {
            sinceCheck += 1
            if sinceCheck >= cancellationInterval {
                sinceCheck = 0
                try Task.checkCancellation()
            }
            let flags = store.flags[index]
            if flags.contains(.removed) || flags.contains(.root) { continue }
            let approximate = store.withSearchBytes(index) { name, original in
                needle.withUnsafeBufferPointer { ByteMatcher.match($0, in: name, original: original) }
            }
            guard let (tier, score) = approximate else { continue }
            let node = Int32(index)
            let total = score + boost(node, store: store, now: now)
            top.insert(Scored(node: node, tier: tier, score: total))
        }
        return top.items
    }

    /// The source's within-tier signal: −0.03 per folder level beyond two (at most −0.3) and up to +0.15
    /// for an item modified recently, halving every 30 days.
    static func boost(_ node: Int32, store: NameStore, now: TimeInterval) -> Double {
        let depth = store.depth(node)
        let depthPenalty = -min(0.3, 0.03 * Double(max(0, depth - 2)))
        let age = max(0, now - Double(store.modified[Int(node)]))
        let recency = 0.15 * pow(2, -age / (30 * 24 * 60 * 60))
        return depthPenalty + recency
    }
}

/// The best `capacity` scored nodes seen so far.
struct TopList {
    let capacity: Int
    private(set) var items: [FileSearch.Scored] = []
    private var worstIndex = 0

    init(capacity: Int) {
        self.capacity = capacity
        items.reserveCapacity(capacity)
    }

    mutating func insert(_ item: FileSearch.Scored) {
        if items.count < capacity {
            items.append(item)
            if items.count == capacity { findWorst() }
            return
        }
        guard FileSearch.isBetter(item, items[worstIndex]) else { return }
        items[worstIndex] = item
        findWorst()
    }

    private mutating func findWorst() {
        var worst = 0
        for index in items.indices.dropFirst() where FileSearch.isBetter(items[worst], items[index]) {
            worst = index
        }
        worstIndex = worst
    }
}

/// The byte-level approximation of `FuzzyMatcher` over normalised UTF-8 names: the same tiers (exact,
/// prefix, word start or acronym, substring, subsequence) with scores on the same scale.
///
/// Word starts follow `FuzzyScoring.bonus`: a word byte after any non-word byte (space, delimiter or
/// punctuation), a digit after a letter, and an upper-case letter after a lower-case one. The last needs
/// the raw name (`original`), which is only passed when it lines up byte for byte with the normalised one.
enum ByteMatcher {
    static func isWordByte(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x61 && byte <= 0x7A) || byte >= 0x80
    }

    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    /// Whether a word starts at `position`, as `FuzzyMatcher` decides it.
    static func isWordStart(
        _ position: Int, in name: UnsafeBufferPointer<UInt8>, original: UnsafeBufferPointer<UInt8>?
    ) -> Bool {
        let current = name[position]
        guard isWordByte(current) else { return false }
        guard position > 0 else { return true }
        let previous = name[position - 1]
        if !isWordByte(previous) { return true }
        if isDigit(current) { return !isDigit(previous) }
        guard let original else { return false }
        let upper = original[position]
        let lower = original[position - 1]
        // Camel case, checked against the raw bytes; the folded bytes must be their lower case, so a raw
        // name that does not line up never makes a boundary.
        return upper >= 0x41 && upper <= 0x5A && lower >= 0x61 && lower <= 0x7A && current == upper | 0x20
            && previous == lower
    }

    static func match(
        _ query: UnsafeBufferPointer<UInt8>, in name: UnsafeBufferPointer<UInt8>,
        original: UnsafeBufferPointer<UInt8>? = nil
    ) -> (MatchTier, Double)? {
        let q = query.count
        let n = name.count
        guard q > 0, q <= n else { return nil }
        let length = Double(n)
        let coverage = Double(q) / length

        // Cheap rejection: the query must be a subsequence.
        var next = 0
        for byte in name where next < q && byte == query[next] {
            next += 1
        }
        guard next == q else { return nil }

        if q == n, equal(query, name, at: 0) { return (.exact, 1) }
        if equal(query, name, at: 0) { return (.prefix, coverage) }

        var substring: Int?
        var index = 1
        while index + q <= n {
            if name[index] == query[0], equal(query, name, at: index) {
                if isWordStart(index, in: name, original: original) {
                    return (.wordStart, 0.9 * coverage * (1 - 0.25 * Double(index) / length))
                }
                if substring == nil { substring = index }
            }
            index += 1
        }

        if q >= 2 {
            var initials = 0
            var matched = 0
            for position in 0..<n where isWordStart(position, in: name, original: original) {
                initials += 1
                if matched < q, name[position] == query[matched] { matched += 1 }
            }
            if matched == q {
                return (.wordStart, 0.8 * Double(q) / Double(max(initials, 1)))
            }
        }

        if let substring {
            return (.substring, coverage * (1 - 0.5 * Double(substring) / length))
        }
        return (.fuzzy, 0.5 * coverage)
    }

    @inline(__always)
    private static func equal(_ query: UnsafeBufferPointer<UInt8>, _ name: UnsafeBufferPointer<UInt8>, at offset: Int)
        -> Bool
    {
        for index in 0..<query.count where name[offset + index] != query[index] {
            return false
        }
        return true
    }
}
