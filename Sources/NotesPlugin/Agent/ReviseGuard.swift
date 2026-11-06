import Foundation
import LintelCore

/// What the guard decides about the model's answer (spec "Revise rule", N4, N5). Pure: the model's text goes in,
/// a verdict comes out, and only the commented blocks can differ from the note.
///
/// - The answer is stripped of bidi and zero-width control characters (`MarkdownText.strippingBidiAndControls`).
/// - The whole run is rejected when the answer names a unit that was not asked for, when it has no usable unit at
///   all, or when anything outside the commented blocks would differ afterwards.
/// - A block (a unit) is rejected, and left as it was, when the answer has another number of blocks or another
///   kind of block, contains images, HTML or links the unit did not have, is empty, or is longer than three times
///   the input.
/// - A unit whose blocks are not the blocks the plan saw is skipped as edited by a human.
enum ReviseGuard {
    enum BlockRejection: Equatable, Sendable {
        case missing
        case empty
        case tooLong
        case structureChanged
        case newLink
        case newImage
        case newHTML
    }

    enum RunRejection: Error, Equatable, Sendable {
        /// The answer has no unit section at all, or only empty ones.
        case unusableAnswer
        /// The answer addresses a unit that was not asked for, or the result would differ outside the units.
        case outsideBlockChanged
    }

    struct Applied: Equatable, Sendable {
        var unitID: Int
        var threadIDs: [Int64]
        var blockRange: ClosedRange<Int>
    }

    struct Rejected: Equatable, Sendable {
        var unitID: Int
        var threadIDs: [Int64]
        var reason: BlockRejection
    }

    struct Unchanged: Equatable, Sendable {
        var unitID: Int
        var threadIDs: [Int64]
    }

    struct Verdict: Equatable, Sendable {
        /// The note with the accepted units replaced; equal to the head when nothing was accepted.
        var body: String
        var applied: [Applied]
        var rejected: [Rejected]
        /// Threads the guard left alone because a human edited their block.
        var skipped: [ReviseSkip]
        /// Units whose answer is the input blocks unchanged (the model's own "cannot be applied" answer): not
        /// applied, not counted, and their threads stay open.
        var unchanged: [Unchanged] = []

        var changedBlockCount: Int { applied.reduce(0) { $0 + $1.blockRange.count } }
    }

    /// The answer may be this much longer than the input before it is rejected: three times, and never less than
    /// `minimumAllowance` characters, so a one-line block can take a name and a date.
    static let growthFactor = 3
    static let minimumAllowance = 120

    static func check(head: String, plan: RevisePlan, answer rawAnswer: String) throws -> Verdict {
        let answers = parse(MarkdownText.strippingBidiAndControls(rawAnswer)).mapValues(ReviseNotesPrompt.unescape)
        guard !answers.isEmpty else { throw RunRejection.unusableAnswer }
        let known = Set(plan.units.map(\.id))
        guard answers.keys.allSatisfy({ known.contains($0) }) else { throw RunRejection.outsideBlockChanged }

        let blocks = MarkdownBlocks.split(head)
        let located = BlockLocator.ranges(of: blocks, in: head)
        var verdict = Verdict(body: head, applied: [], rejected: [], skipped: plan.skipped)
        var replacements: [(range: NSRange, text: String, unit: ReviseUnit)] = []

        for unit in plan.units {
            // A human edited the block between planning and now: its text is not what the model was shown.
            guard unit.blockRange.upperBound < blocks.count,
                Array(blocks[unit.blockRange]) == unit.blocks,
                let first = located[unit.blockRange.lowerBound], let last = located[unit.blockRange.upperBound]
            else {
                verdict.skipped.append(ReviseSkip(threadIDs: unit.threadIDs, reason: .editedAfterComment))
                continue
            }
            guard let answer = answers[unit.id] else {
                verdict.rejected.append(Rejected(unitID: unit.id, threadIDs: unit.threadIDs, reason: .missing))
                continue
            }
            if let reason = rejection(of: answer, for: unit) {
                verdict.rejected.append(Rejected(unitID: unit.id, threadIDs: unit.threadIDs, reason: reason))
                continue
            }
            let newBlocks = MarkdownBlocks.split(answer)
            if newBlocks == unit.blocks {
                verdict.unchanged.append(Unchanged(unitID: unit.id, threadIDs: unit.threadIDs))
                continue
            }
            // The text between two blocks of the unit stays as the note had it (a list keeps its line breaks).
            let source = head as NSString
            var text = ""
            for (offset, block) in newBlocks.enumerated() {
                text += block
                if offset < newBlocks.count - 1 {
                    let from = located[unit.blockRange.lowerBound + offset]
                    let to = located[unit.blockRange.lowerBound + offset + 1]
                    if let from, let to, to.location >= from.location + from.length {
                        text += source.substring(
                            with: NSRange(
                                location: from.location + from.length,
                                length: to.location - (from.location + from.length)))
                    } else {
                        text += "\n\n"
                    }
                }
            }
            let range = NSRange(location: first.location, length: last.location + last.length - first.location)
            replacements.append((range, text, unit))
        }

        var body = head as NSString
        for item in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            body = body.replacingCharacters(in: item.range, with: item.text) as NSString
        }
        let result = body as String
        try verifyOutside(of: replacements.map(\.unit), head: head, result: result)
        verdict.body = result
        verdict.applied = replacements.map {
            Applied(unitID: $0.unit.id, threadIDs: $0.unit.threadIDs, blockRange: $0.unit.blockRange)
        }.sorted { $0.unitID < $1.unitID }
        return verdict
    }

    // MARK: Answer

    /// `[[unit N]]` alone on a line starts unit N's answer; text before the first marker is ignored.
    static func parse(_ answer: String) -> [Int: String] {
        var result: [Int: [String]] = [:]
        var current: Int?
        for line in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[[unit "), trimmed.hasSuffix("]]"),
                let id = Int(trimmed.dropFirst(7).dropLast(2).trimmingCharacters(in: .whitespaces))
            {
                current = id
                result[id] = result[id] ?? []
            } else if let current {
                result[current, default: []].append(String(line))
            }
        }
        return result.compactMapValues { lines in
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "" : text
        }
    }

    private static func rejection(of answer: String, for unit: ReviseUnit) -> BlockRejection? {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        let input = unit.blocks.joined(separator: "\n\n")
        if answer.count > max(growthFactor * input.count, minimumAllowance) { return .tooLong }
        let newBlocks = MarkdownBlocks.split(answer)
        guard newBlocks.count == unit.blocks.count,
            zip(newBlocks, unit.blocks).allSatisfy({ ReviseBlockKind.of($0) == ReviseBlockKind.of($1) })
        else { return .structureChanged }
        let allowed = ReviseTokens.of(input)
        let found = ReviseTokens.of(answer).subtracting(allowed)
        if found.contains(where: { $0.hasPrefix("image:") }) { return .newImage }
        if found.contains(where: { $0.hasPrefix("html:") }) { return .newHTML }
        if !found.isEmpty { return .newLink }
        return nil
    }

    /// Defensive: every block outside the units is the same afterwards, in the same order.
    private static func verifyOutside(of units: [ReviseUnit], head: String, result: String) throws {
        let before = MarkdownBlocks.split(head)
        let after = MarkdownBlocks.split(result)
        var expected: [String] = []
        var index = 0
        let sorted = units.sorted { $0.blockRange.lowerBound < $1.blockRange.lowerBound }
        var outsideBefore: [String] = []
        for unit in sorted {
            outsideBefore.append(contentsOf: before[index..<unit.blockRange.lowerBound])
            index = unit.blockRange.upperBound + 1
        }
        outsideBefore.append(contentsOf: before[min(index, before.count)...])
        expected = outsideBefore
        // The result's blocks minus the replacement blocks, found by position: the count must be unchanged.
        guard after.count == before.count else { throw RunRejection.outsideBlockChanged }
        var outsideAfter: [String] = []
        index = 0
        for unit in sorted {
            outsideAfter.append(contentsOf: after[index..<unit.blockRange.lowerBound])
            index = unit.blockRange.upperBound + 1
        }
        outsideAfter.append(contentsOf: after[min(index, after.count)...])
        guard outsideAfter == expected else { throw RunRejection.outsideBlockChanged }
    }
}

/// The kind of a block, by its first line: a rewritten block must keep it (spec: same block type and count).
enum ReviseBlockKind: Equatable, Sendable {
    case heading(Int)
    case bullet
    case numbered
    case task
    case table
    case code
    case quote
    case paragraph

    static func of(_ block: String) -> ReviseBlockKind {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        let first = (lines.first ?? "").drop { $0 == " " || $0 == "\t" }
        if first.hasPrefix("```") || first.hasPrefix("~~~") { return .code }
        let hashes = first.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), first.dropFirst(hashes).first == " " { return .heading(hashes) }
        for marker in ["- ", "* ", "+ "] where first.hasPrefix(marker) {
            let rest = first.dropFirst(2)
            if rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return .task }
            return .bullet
        }
        let digits = first.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let rest = first.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return .numbered }
        }
        if first.hasPrefix(">") { return .quote }
        if lines.count >= 2, first.contains("|"), isTableSeparator(lines[1]) { return .table }
        return .paragraph
    }

    private static func isTableSeparator(_ line: Substring) -> Bool {
        let cells = line.trimmingCharacters(in: .whitespaces)
        guard cells.contains("-"), cells.contains("|") else { return false }
        return cells.allSatisfy { "|-: \t".contains($0) }
    }
}

/// The links, images and HTML a text contains, as comparable tokens: the output may only use tokens the input has.
enum ReviseTokens {
    static func of(_ text: String) -> Set<String> {
        var tokens = Set<String>()
        for match in text.matches(of: /!\[[^\]]*\](?:\([^)]*\)|\[[^\]]*\])?/) {
            tokens.insert("image:" + match.output)
        }
        let withoutImages = text.replacing(/!\[[^\]]*\](?:\([^)]*\)|\[[^\]]*\])?/, with: "")
        for match in withoutImages.matches(of: /\[[^\]]*\]\(([^)]*)\)/) {
            tokens.insert("link:" + match.output.1)
        }
        for match in withoutImages.matches(of: /\[[^\]]+\]\[[^\]]*\]/) { tokens.insert("link:" + match.output) }
        for match in withoutImages.matches(of: /<\/?[A-Za-z][^>]*>|<!--/) {
            tokens.insert("html:" + match.output.lowercased())
        }
        // Any other scheme a link can carry, `www.` and a bare domain with a path: none may appear from nowhere.
        let lowered = withoutImages.lowercased()
        let urlPattern =
            /(?:(?:https?|ftp|ftps|sftp|ssh|file|tel|sms|data|javascript|vbscript|mailto|callto|facetime|slack|zoommtg|zoomus|webcal):[^\s)>\]]*|www\.[^\s)>\]]+|(?:[a-z0-9-]+\.)+[a-z]{2,}\/[^\s)>\]]*)/
        for match in lowered.matches(of: urlPattern) { tokens.insert("url:" + match.output) }
        return tokens
    }
}
