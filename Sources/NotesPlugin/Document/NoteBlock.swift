import Foundation
import LintelCore
import LintelKit

/// One block of a layer as the read-only document draws it: the Markdown subset the notes composer and the
/// transcripts use (headings, paragraphs, list items, tables, code, quotes). Nothing here renders HTML, loads an
/// image or follows a link; text reaches the screen through `NoteInline`.
struct NoteBlock: Identifiable, Equatable, Sendable {
    enum Marker: Equatable, Sendable {
        case bullet
        case number(Int)
        case task(done: Bool)
    }

    struct ListLine: Equatable, Sendable {
        var depth: Int
        var marker: Marker
        var text: String
    }

    struct Table: Equatable, Sendable {
        var header: [String]
        var rows: [[String]]
    }

    enum Kind: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list([ListLine])
        case table(Table)
        case code(String)
        case quote(String)
    }

    /// The index in `MarkdownBlocks.split`, the one provenance and comments address.
    var index: Int
    var kind: Kind
    /// The block's Markdown as the source wrote it (a transcript segment is drawn from this, whatever it parses as).
    var source = ""
    /// Times (ms) of the recording the block quotes, from the layer's provenance.
    var quoteTimesMs: [Int] = []
    var speakerID: String?
    /// The start of the segment of a transcript block.
    var startMs: Int?

    var id: Int { index }
}

enum NoteBlocks {
    /// The blocks of a layer, with the layer's provenance attached by block index.
    static func parse(_ layer: NoteLayer) -> [NoteBlock] {
        var provenance: [Int: NoteBlockProvenance] = [:]
        for entry in layer.provenance where provenance[entry.blockIndex] == nil { provenance[entry.blockIndex] = entry }
        return MarkdownBlocks.split(layer.markdown).enumerated().map { index, text in
            let facts = provenance[index]
            return NoteBlock(
                index: index, kind: kind(of: text), source: text, quoteTimesMs: facts?.quoteTimesMs ?? [],
                speakerID: facts?.speakerID, startMs: facts?.startMs)
        }
    }

    static func kind(of block: String) -> NoteBlock.Kind {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return .paragraph("") }
        if first.hasPrefix("```") || first.hasPrefix("~~~") { return .code(codeBody(lines)) }
        if let heading = heading(first), lines.count == 1 { return heading }
        if isTable(lines) { return .table(table(lines)) }
        if listLine(first) != nil { return .list(listLines(lines)) }
        if first.hasPrefix(">") {
            let text = lines.map { $0.drop { $0 == ">" || $0 == " " } }.joined(separator: " ")
            return .quote(text)
        }
        return .paragraph(lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))
    }

    // MARK: Headings and code

    private static func heading(_ line: String) -> NoteBlock.Kind? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " else { return nil }
        let text = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        return .heading(level: hashes.count, text: text)
    }

    private static func codeBody(_ lines: [String]) -> String {
        var body = Array(lines.dropFirst())
        if let last = body.last, last.hasPrefix("```") || last.hasPrefix("~~~") { body.removeLast() }
        return body.joined(separator: "\n")
    }

    // MARK: Lists

    /// A list line: its indentation (two spaces or a tab per level), marker and text.
    private static func listLine(_ line: String) -> NoteBlock.ListLine? {
        var indent = 0
        var rest = Substring(line)
        while let head = rest.first, head == " " || head == "\t" {
            indent += head == "\t" ? 2 : 1
            rest = rest.dropFirst()
        }
        let depth = indent / 2
        for bullet in ["- ", "* ", "+ "] where rest.hasPrefix(bullet) {
            var text = rest.dropFirst(2)
            var marker = NoteBlock.Marker.bullet
            if text.hasPrefix("[ ] ") {
                marker = .task(done: false)
                text = text.dropFirst(4)
            } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                marker = .task(done: true)
                text = text.dropFirst(4)
            }
            return NoteBlock.ListLine(depth: depth, marker: marker, text: String(text))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count <= 9, let number = Int(digits) {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return NoteBlock.ListLine(depth: depth, marker: .number(number), text: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    /// The first line is the item; later lines are nested items, or continuation text of the line before.
    private static func listLines(_ lines: [String]) -> [NoteBlock.ListLine] {
        var result: [NoteBlock.ListLine] = []
        for line in lines {
            if let item = listLine(line) {
                result.append(item)
            } else if !result.isEmpty {
                let extra = line.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty { result[result.count - 1].text += " " + extra }
            }
        }
        return result
    }

    // MARK: Tables

    private static func isTable(_ lines: [String]) -> Bool {
        guard lines.count >= 2, lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return false }
        let separator = lines[1].trimmingCharacters(in: .whitespaces)
        return separator.contains("-") && separator.allSatisfy { "|-: \t".contains($0) }
    }

    private static func table(_ lines: [String]) -> NoteBlock.Table {
        NoteBlock.Table(header: cells(lines[0]), rows: lines.dropFirst(2).map(cells))
    }

    /// The cells of one row; `\|` stays inside a cell.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The time a block quotes: a trailing `[mm:ss]` or `[h:mm:ss]` (the composer escapes the brackets).
enum NoteQuote {
    /// The text without its trailing time, and that time in milliseconds.
    static func split(_ text: String) -> (text: String, timeMs: Int?) {
        guard let match = text.firstMatch(of: /\s*\\?\[([0-9]{1,2}(?::[0-9]{2}){1,2})\\?\]\s*$/),
            let ms = milliseconds(String(match.output.1))
        else { return (text, nil) }
        return (String(text[..<match.range.lowerBound]), ms)
    }

    static func milliseconds(_ clock: String) -> Int? {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == clock.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds * 1000
    }

    /// "12:41", or "1:02:03" past an hour.
    static func clock(milliseconds: Int) -> String {
        let total = max(0, milliseconds) / 1000
        let (hours, minutes, seconds) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

/// Text from a source on its way to a `Text`: inline Markdown only (bold, italic, code), no link, no image, no
/// bidirectional or control characters.
enum NoteInline {
    static func attributed(_ text: String) -> AttributedString {
        let cleaned = MarkdownText.strippingBidiAndControls(text)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        guard var result = try? AttributedString(markdown: cleaned, options: options) else {
            return AttributedString(cleaned)
        }
        for run in result.runs where run.link != nil || run.imageURL != nil {
            result[run.range].link = nil
            result[run.range].imageURL = nil
        }
        return result
    }
}
