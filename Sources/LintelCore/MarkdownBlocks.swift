import Foundation

/// Splits Markdown source into the blocks that comment anchors, block attribution and the quote provenance of
/// meeting notes address by index. Pure, no I/O.
///
/// The rules (spec `2026-11-04-notes-workspace`, ADR 0008 addendum 0.3): blocks are separated by blank lines; a
/// fenced code block stays one block, blank lines inside it included; a table stays one block (its rows are
/// consecutive lines); every top-level list item is its own block together with its indented continuation lines,
/// nested items included; leading and trailing whitespace of a block is trimmed and empty blocks are dropped.
public enum MarkdownBlocks {
    public static func split(_ markdown: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring] = []
        // The opening fence: its character and length. A closing fence repeats the character at least as often.
        var openFence: (marker: Character, length: Int)?
        // True when the open fence is indented inside a list item: it stays in the item's block.
        var fenceInItem = false

        func flush() {
            let text = current.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: " \t\n"))
            if !text.isEmpty { blocks.append(text) }
            current = []
        }

        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            if let open = openFence {
                current.append(line)
                if let fence = fence(in: trimmed), fence.marker == open.marker, fence.length >= open.length,
                    trimmed.dropFirst(fence.length).allSatisfy({ $0 == " " || $0 == "\t" })
                {
                    openFence = nil
                    if fenceInItem {
                        fenceInItem = false
                    } else {
                        flush()
                    }
                }
                continue
            }
            if let fence = fence(in: trimmed) {
                if trimmed.count < line.count, let first = current.first, isListItemStart(first) {
                    fenceInItem = true
                } else {
                    flush()
                }
                current.append(line)
                openFence = fence
            } else if trimmed.isEmpty {
                flush()
            } else if isListItemStart(line) {
                flush()
                current.append(line)
            } else {
                current.append(line)
            }
        }
        // An unterminated fence runs to the end of the text and is still one block.
        flush()
        return blocks
    }

    /// A line that starts with at least three backticks or tildes.
    private static func fence(in trimmed: Substring) -> (marker: Character, length: Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix { $0 == first }.count
        guard length >= 3 else { return nil }
        // The info string of a backtick fence cannot contain a backtick: "```x```" is inline code.
        if first == "`", trimmed.dropFirst(length).contains("`") { return nil }
        return (first, length)
    }

    /// A top-level list item: no indentation, `- `, `* `, `+ ` or digits followed by `. ` or `) `.
    private static func isListItemStart(_ line: Substring) -> Bool {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }
}
