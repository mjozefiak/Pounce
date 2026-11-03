import Foundation

/// Re-renders the model-composed notes through an allow-list. The notes are never trusted as Markdown: they
/// are parsed line by line into headings, paragraphs and bullet or numbered lists with `*emphasis*` and
/// `**strong**`, and every text run is written out with the same backslash escape as any other plain text
/// (`MarkdownExporter.escape`). Whatever the parser does not recognise (links, images, HTML, reference
/// definitions, quotes, code fences, tables, thematic breaks, setext underlines) stays in the text as
/// escaped characters, so nothing can render as a link, image, tag or code, nothing is fetched and the notes
/// cannot open or close a fence, a heading of the document (`## Transcript`) or a list of the export.
enum NotesMarkdown {
    /// The headings of the notes start below the document's own `##` sections.
    static let firstHeadingLevel = 3
    static let maxHeadingLevel = 6
    static let maxListDepth = 4

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case item(depth: Int, number: Int?, text: String)
    }

    static func render(_ text: String) -> String {
        let blocks = parse(MarkdownExporter.cleaned(text, keepNewlines: true))
        let smallest =
            blocks.compactMap { block -> Int? in
                if case .heading(let level, _) = block { level } else { nil }
            }.min() ?? firstHeadingLevel
        var lines: [String] = []
        var previousWasItem = false
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                if !lines.isEmpty { lines.append("") }
                let depth = min(firstHeadingLevel + level - smallest, maxHeadingLevel)
                lines.append(String(repeating: "#", count: depth) + " " + inline(text))
                previousWasItem = false
            case .paragraph(let text):
                if !lines.isEmpty { lines.append("") }
                lines.append(escapeLineStart(inline(text)))
                previousWasItem = false
            case .item(let depth, let number, let text):
                if !previousWasItem, !lines.isEmpty { lines.append("") }
                let marker = number.map { "\($0)." } ?? "-"
                lines.append(String(repeating: " ", count: depth * 4) + marker + " " + inline(text))
                previousWasItem = true
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Block parser

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var indents: [Int] = []
        var lastWasItem = false

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty {
                flush()
                lastWasItem = false
                continue
            }
            let indent = leadingColumns(line)
            if indent < 4, let heading = heading(body) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
                indents = []
                lastWasItem = false
            } else if let item = listItem(body) {
                flush()
                while let top = indents.last, indent < top { indents.removeLast() }
                if indents.last.map({ indent > $0 }) ?? true { indents.append(indent) }
                blocks.append(
                    .item(depth: min(indents.count - 1, maxListDepth), number: item.number, text: item.text))
                lastWasItem = true
            } else if lastWasItem, case .item(let depth, let number, let text)? = blocks.last {
                blocks[blocks.count - 1] = .item(depth: depth, number: number, text: text + " " + body)
            } else {
                paragraph.append(body)
                indents = []
            }
        }
        flush()
        return blocks
    }

    private static func leadingColumns(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4
            } else {
                break
            }
        }
        return columns
    }

    private static func heading(_ body: String) -> (level: Int, text: String)? {
        guard let match = body.wholeMatch(of: /(#{1,6})[ ]+(.+?)(?:[ ]+#+)?/) else { return nil }
        let text = String(match.2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (match.1.count, text)
    }

    private static func listItem(_ body: String) -> (number: Int?, text: String)? {
        if let match = body.wholeMatch(of: /[-*+][ ]+(.+)/) { return (nil, String(match.1)) }
        if let match = body.wholeMatch(of: /(\d{1,9})[.)][ ]+(.+)/), let number = Int(match.1) {
            return (number, String(match.2))
        }
        return nil
    }

    // MARK: Inline

    /// `**strong**`, `__strong__`, `*emphasis*` and `_emphasis_` on one line stay; everything else is text.
    /// The content of an emphasis run is plain text (no nesting).
    private static func inline(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = ""
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "*" || scalar == "_", let span = emphasis(in: scalars, at: index) {
                let marker = span.length == 2 ? "**" : "*"
                let content = String(String.UnicodeScalarView(scalars[span.contentStart..<span.contentEnd]))
                output += marker + MarkdownExporter.escape(content) + marker
                index = span.contentEnd + span.length
                continue
            }
            output += MarkdownExporter.escape(String(scalar))
            index += 1
        }
        return MarkdownExporter.breakAutolinks(output)
    }

    private static func emphasis(in scalars: [Unicode.Scalar], at start: Int) -> (
        length: Int, contentStart: Int, contentEnd: Int
    )? {
        let delimiter = scalars[start]
        var length = 0
        while start + length < scalars.count, scalars[start + length] == delimiter { length += 1 }
        guard length <= 2 else { return nil }
        if delimiter == "_", start > 0, isWordScalar(scalars[start - 1]) { return nil }
        let contentStart = start + length
        guard contentStart < scalars.count, !isSpace(scalars[contentStart]) else { return nil }
        var index = contentStart
        while index < scalars.count {
            if scalars[index] == delimiter {
                var run = 0
                while index + run < scalars.count, scalars[index + run] == delimiter { run += 1 }
                if run == length, index > contentStart, !isSpace(scalars[index - 1]) {
                    let after = index + run
                    if delimiter == "*" || after >= scalars.count || !isWordScalar(scalars[after]) {
                        return (length, contentStart, index)
                    }
                }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// A paragraph starts a line: a leading `-`, `+`, `=` or `1.` would open a list, a rule or a setext heading.
    private static func escapeLineStart(_ line: String) -> String {
        guard let first = line.unicodeScalars.first else { return line }
        if "-+=".unicodeScalars.contains(first) { return "\\" + line }
        if let match = line.prefixMatch(of: /\d{1,9}[.)]/) {
            let digits = line[line.startIndex..<line.index(before: match.range.upperBound)]
            return digits + "\\" + line[line.index(before: match.range.upperBound)...]
        }
        return line
    }
}
