import Foundation
import LintelCore

/// What one comment thread points at, as the Revise run sees it: a block or a few neighbouring blocks, the
/// comments, and the blocks around them as read-only context. Text of the note and of its comments: never logged.
struct ReviseUnit: Equatable, Sendable {
    /// 1-based, the number the prompt and the answer use.
    var id: Int
    var threadIDs: [Int64]
    /// Indexes in `MarkdownBlocks.split` of the head the unit was planned on.
    var blockRange: ClosedRange<Int>
    var blocks: [String]
    var comments: [String]
    var before: [String]
    var after: [String]
}

/// A thread the run did not touch, and why. The UI says it in words ("You edited this block, so it was not
/// changed"); nothing here carries text.
struct ReviseSkip: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The commented text is no longer in the note, or sits in no block.
        case textChanged
        /// A human edited the block after the comment (its text no longer matches `anchor_block_hash`).
        case editedAfterComment
        /// The prompt would not fit the model's context; the thread stays open for the next run.
        case deferred
    }

    var threadIDs: [Int64]
    var reason: Reason
}

struct RevisePlan: Equatable, Sendable {
    var units: [ReviseUnit]
    var skipped: [ReviseSkip]
}

/// Plans a run over the OPEN threads of one document (spec "Revise rule"): every thread names the blocks its quote
/// touches now; threads touching a common block form one unit, which is revised as a whole. Pure.
enum ReviseUnitPlanner {
    /// Blocks of context on each side of a unit.
    static let contextBlocks = 2
    /// The most characters of blocks, context and comments one run sends (the context is 8192 tokens, and the
    /// answer needs room too).
    static let inputBudget = 9000

    static func plan(head: String, threads: [CommentThread], inputBudget: Int = inputBudget) -> RevisePlan {
        let blocks = MarkdownBlocks.split(head)
        let located = BlockLocator.ranges(of: blocks, in: head)
        var skipped: [ReviseSkip] = []
        // (thread, first block, last block)
        var touched: [(thread: CommentThread, lo: Int, hi: Int)] = []
        for thread in threads where thread.isOpen {
            guard let range = AnchorResolver.resolve(thread.anchor, in: head).range else {
                skipped.append(ReviseSkip(threadIDs: [thread.id], reason: .textChanged))
                continue
            }
            var indexes: [Int] = []
            for (index, found) in located.enumerated() {
                if let found, NSIntersectionRange(found, range).length > 0 { indexes.append(index) }
            }
            guard let lo = indexes.first, let hi = indexes.last else {
                skipped.append(ReviseSkip(threadIDs: [thread.id], reason: .textChanged))
                continue
            }
            // The hash was taken from the blocks the selection touched at comment time; a different text now means
            // a human edited them since (spec: skipped and reported).
            let hash = CommentAnchors.hash(indexes.map { blocks[$0] }.joined(separator: "\n\n"))
            guard hash == thread.anchor.blockHash else {
                skipped.append(ReviseSkip(threadIDs: [thread.id], reason: .editedAfterComment))
                continue
            }
            touched.append((thread, lo, hi))
        }
        var groups: [(lo: Int, hi: Int, threads: [CommentThread])] = []
        for item in touched.sorted(by: { ($0.lo, $0.hi, $0.thread.id) < ($1.lo, $1.hi, $1.thread.id) }) {
            if let last = groups.last, item.lo <= last.hi {
                groups[groups.count - 1] = (last.lo, max(last.hi, item.hi), last.threads + [item.thread])
            } else {
                groups.append((item.lo, item.hi, [item.thread]))
            }
        }
        var units: [ReviseUnit] = []
        var used = 0
        for group in groups {
            let unitBlocks = Array(blocks[group.lo...group.hi])
            let comments = group.threads.flatMap { $0.comments.map(\.body) }
            let before = Array(blocks[max(0, group.lo - contextBlocks)..<group.lo])
            let after = Array(blocks[(group.hi + 1)..<min(blocks.count, group.hi + 1 + contextBlocks)])
            let cost = (unitBlocks + comments + before + after).reduce(0) { $0 + $1.count }
            if used + cost > inputBudget, !units.isEmpty {
                skipped.append(ReviseSkip(threadIDs: group.threads.map(\.id), reason: .deferred))
                continue
            }
            used += cost
            units.append(
                ReviseUnit(
                    id: units.count + 1, threadIDs: group.threads.map(\.id), blockRange: group.lo...group.hi,
                    blocks: unitBlocks, comments: comments, before: before, after: after))
        }
        return RevisePlan(units: units, skipped: skipped)
    }
}
