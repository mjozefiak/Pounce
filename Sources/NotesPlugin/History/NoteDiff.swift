import Foundation
import LintelCore
import LintelKit

/// One line of the inline Compare (prototype `.dl`): a block that stayed (only the headings that frame a change),
/// one that went, one that came. Holds note text: never logged.
struct NoteDiffLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case context, removed, added }

    var id: Int
    var kind: Kind
    var text: String
    /// Who wrote the block (`removed`: in the older revision, `added`: in the newer one); `nil` for context.
    var author: NoteAuthor?
}

/// A block-level diff of two revisions, pure. Blocks are `MarkdownBlocks.split`, the unit authorship and comments
/// use, so a changed sentence is one removed and one added block.
enum NoteDiff {
    /// A pair of bodies this large is compared as "everything replaced" instead of by the quadratic table.
    static let tableLimit = 4_000_000

    struct Result: Equatable, Sendable {
        var lines: [NoteDiffLine]
        var added: Int
        var removed: Int
        /// Pairs of a removed and an added block: "edited".
        var edited: Int { min(added, removed) }
        var isEmpty: Bool { added == 0 && removed == 0 }
    }

    /// `oldAuthors` / `newAuthors` are the stored authors per block (`blocks_json`), when the revision has them.
    static func compare(old: String, oldAuthors: [String]?, new: String, newAuthors: [String]?) -> Result {
        let a = MarkdownBlocks.split(old)
        let b = MarkdownBlocks.split(new)
        let ops = script(a, b)
        var raw: [NoteDiffLine] = []
        var added = 0
        var removed = 0
        for op in ops {
            switch op {
            case .keep(_, let j):
                raw.append(NoteDiffLine(id: raw.count, kind: .context, text: b[j], author: nil))
            case .remove(let i):
                removed += 1
                raw.append(
                    NoteDiffLine(id: raw.count, kind: .removed, text: a[i], author: author(oldAuthors, at: i)))
            case .add(let j):
                added += 1
                raw.append(NoteDiffLine(id: raw.count, kind: .added, text: b[j], author: author(newAuthors, at: j)))
            }
        }
        return Result(lines: framed(raw), added: added, removed: removed)
    }

    private static func author(_ authors: [String]?, at index: Int) -> NoteAuthor? {
        guard let authors, index < authors.count else { return nil }
        return NoteAuthor(rawValue: authors[index])
    }

    private enum Op {
        case keep(Int, Int)
        case remove(Int)
        case add(Int)
    }

    /// The edit script by longest common subsequence. Removals come before additions inside a changed stretch.
    private static func script(_ a: [String], _ b: [String]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        let ma = a.count - prefix - suffix
        let mb = b.count - prefix - suffix
        var ops: [Op] = (0..<prefix).map { .keep($0, $0) }
        if ma * mb > tableLimit {
            ops += (0..<ma).map { .remove(prefix + $0) }
            ops += (0..<mb).map { .add(prefix + $0) }
        } else if ma == 0 || mb == 0 {
            ops += (0..<ma).map { .remove(prefix + $0) }
            ops += (0..<mb).map { .add(prefix + $0) }
        } else {
            var table = [[Int]](repeating: [Int](repeating: 0, count: mb + 1), count: ma + 1)
            for i in stride(from: ma - 1, through: 0, by: -1) {
                for j in stride(from: mb - 1, through: 0, by: -1) {
                    table[i][j] =
                        a[prefix + i] == b[prefix + j]
                        ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
            var i = 0
            var j = 0
            var pendingAdds: [Int] = []
            func flush() {
                ops += pendingAdds.map { .add($0) }
                pendingAdds = []
            }
            while i < ma || j < mb {
                if i < ma, j < mb, a[prefix + i] == b[prefix + j] {
                    flush()
                    ops.append(.keep(prefix + i, prefix + j))
                    i += 1
                    j += 1
                } else if j < mb, i == ma || table[i][j + 1] >= table[i + 1][j] {
                    pendingAdds.append(prefix + j)
                    j += 1
                } else {
                    ops.append(.remove(prefix + i))
                    i += 1
                }
            }
            flush()
        }
        ops += (0..<suffix).map { .keep(a.count - suffix + $0, b.count - suffix + $0) }
        return ops
    }

    /// Keeps the changes and, as context, the heading that frames each stretch of changes (prototype: `## Decisions`
    /// above the change under it). Other unchanged blocks are left out.
    private static func framed(_ lines: [NoteDiffLine]) -> [NoteDiffLine] {
        var result: [NoteDiffLine] = []
        var heading: NoteDiffLine?
        for line in lines {
            switch line.kind {
            case .context:
                heading = line.text.hasPrefix("#") ? line : nil
            default:
                if let framing = heading {
                    result.append(framing)
                    heading = nil
                }
                result.append(line)
            }
        }
        return result.enumerated().map { index, line in
            var numbered = line
            numbered.id = index
            return numbered
        }
    }
}
