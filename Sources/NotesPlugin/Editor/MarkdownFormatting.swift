import Foundation

/// What the format bar and the ⌘B / ⌘I keys ask for.
enum NoteFormatAction: Equatable, CaseIterable, Sendable {
    case paragraph
    case heading(Int)
    case bold
    case italic
    case strike
    case bulletList
    case taskList
    case quote
    case link

    static let allCases: [NoteFormatAction] = [
        .paragraph, .heading(1), .heading(2), .heading(3), .bold, .italic, .strike, .bulletList, .taskList, .quote,
        .link,
    ]
}

/// One change to the Markdown source: replace `range` (UTF-16 offsets) with `replacement`, then select
/// `selection` (offsets in the new text). Pure: the editor applies it through `shouldChangeText`, so undo,
/// the delegate and the restyle all see an ordinary edit.
struct NoteTextEdit: Equatable, Sendable {
    var range: Range<Int>
    var replacement: String
    var selection: Range<Int>
}

/// The format actions as text transforms on the Markdown source. The stored text stays Markdown: bold writes
/// `**`, a heading writes `#`, and the markers stay visible.
enum MarkdownFormatting {
    static func edit(_ action: NoteFormatAction, in text: String, selection: Range<Int>) -> NoteTextEdit? {
        let units = Array(text.utf16)
        let selection = max(0, min(selection.lowerBound, units.count))..<max(0, min(selection.upperBound, units.count))
        switch action {
        case .bold: return wrap(units, selection, marker: "**")
        case .italic: return wrap(units, selection, marker: "*")
        case .strike: return wrap(units, selection, marker: "~~")
        case .link: return link(units, selection)
        case .paragraph: return prefix(units, selection, make: .paragraph)
        case .heading(let level): return prefix(units, selection, make: .heading(min(max(level, 1), 3)))
        case .bulletList: return prefix(units, selection, make: .bullet)
        case .taskList: return prefix(units, selection, make: .task)
        case .quote: return prefix(units, selection, make: .quote)
        }
    }

    // MARK: Inline

    private static func string(_ units: [UInt16], _ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }

    private static func wrap(_ units: [UInt16], _ selection: Range<Int>, marker: String) -> NoteTextEdit {
        let width = marker.utf16.count
        let marks = Array(marker.utf16)
        func has(_ at: Int) -> Bool {
            at >= 0 && at + width <= units.count && Array(units[at..<(at + width)]) == marks
        }
        let single = marker == "*"
        // The markers sit outside the selection: take them off.
        if has(selection.lowerBound - width), has(selection.upperBound),
            !(single && (isStar(units, selection.lowerBound - width - 1) || isStar(units, selection.upperBound + 1)))
        {
            let from = selection.lowerBound - width
            let to = selection.upperBound + width
            let inner = string(units, selection)
            return NoteTextEdit(
                range: from..<to, replacement: inner, selection: from..<(from + inner.utf16.count))
        }
        // The markers are the first and last characters of the selection: take them off.
        if selection.count >= 2 * width, has(selection.lowerBound), has(selection.upperBound - width),
            !(single && (isStar(units, selection.lowerBound + 1) || isStar(units, selection.upperBound - 2)))
        {
            let inner = string(units, (selection.lowerBound + width)..<(selection.upperBound - width))
            return NoteTextEdit(
                range: selection, replacement: inner,
                selection: selection.lowerBound..<(selection.lowerBound + inner.utf16.count))
        }
        let inner = string(units, selection)
        let start = selection.lowerBound + width
        return NoteTextEdit(
            range: selection, replacement: marker + inner + marker,
            selection: start..<(start + inner.utf16.count))
    }

    private static func isStar(_ units: [UInt16], _ at: Int) -> Bool {
        at >= 0 && at < units.count && units[at] == 0x2A
    }

    /// `[text]()` with the caret in the parentheses, ready for the address; an empty selection gives `[]()` with
    /// the caret in the brackets. The editor never opens or loads what the address says.
    private static func link(_ units: [UInt16], _ selection: Range<Int>) -> NoteTextEdit {
        let inner = string(units, selection)
        if selection.isEmpty {
            let caret = selection.lowerBound + 1
            return NoteTextEdit(range: selection, replacement: "[]()", selection: caret..<caret)
        }
        let caret = selection.lowerBound + inner.utf16.count + 3
        return NoteTextEdit(range: selection, replacement: "[" + inner + "]()", selection: caret..<caret)
    }

    // MARK: Lines

    private enum Wanted: Equatable {
        case paragraph
        case heading(Int)
        case bullet
        case task
        case quote

        var prefix: String {
            switch self {
            case .paragraph: ""
            case .heading(let level): String(repeating: "#", count: level) + " "
            case .bullet: "- "
            case .task: "- [ ] "
            case .quote: "> "
            }
        }

        func matches(_ kind: MarkdownLinePrefix.Kind) -> Bool {
            switch (self, kind) {
            case (.heading(let level), .heading(let found)): level == found
            case (.bullet, .bullet), (.task, .task), (.quote, .quote): true
            case (.paragraph, .none): true
            default: false
            }
        }
    }

    /// Sets the prefix of every line the selection touches; when all of them already have it, takes it off.
    /// A heading, a list item and a quote replace each other (one block prefix per line, as in Markdown).
    private static func prefix(_ units: [UInt16], _ selection: Range<Int>, make wanted: Wanted) -> NoteTextEdit? {
        // The lines touched: from the start of the first to the end of the last (a selection ending right
        // after a line break does not touch the next line).
        let first = MarkdownSourceScanner.lineRange(in: units, at: lineStart(units, selection.lowerBound))
        var lines: [MarkdownSourceScanner.LineBounds] = [first]
        while lines[lines.count - 1].next <= (selection.isEmpty ? -1 : selection.upperBound - 1),
            lines[lines.count - 1].next < units.count
        {
            lines.append(MarkdownSourceScanner.lineRange(in: units, at: lines[lines.count - 1].next))
        }
        let single = lines.count == 1
        let candidates = lines.filter { single || !MarkdownSourceScanner.isBlank(units, $0.start..<$0.contentEnd) }
        guard !candidates.isEmpty else { return nil }
        let parsed = candidates.map { MarkdownLinePrefix.parse(units, line: $0.start..<$0.contentEnd) }
        let removing = wanted != .paragraph && parsed.allSatisfy { wanted.matches($0.kind) }
        var output = ""
        var cursor = first.start
        var firstDelta = 0
        var firstPrefixEnd = first.start
        for (offset, line) in candidates.enumerated() {
            output += string(units, cursor..<line.start)
            let old = parsed[offset]
            let rest = string(units, (line.start + old.length)..<line.contentEnd)
            let indent =
                old.kind == .none || old.kind == .quote
                ? "" : string(units, line.start..<(line.start + leading(units, line)))
            let newPrefix = removing || wanted == .paragraph ? "" : wanted.prefix
            let kept = (wanted == .bullet || wanted == .task) && !removing ? indent : ""
            output += kept + newPrefix + rest
            if offset == 0 {
                firstDelta = (kept + newPrefix).utf16.count - old.length
                firstPrefixEnd = line.start + (kept + newPrefix).utf16.count
            }
            cursor = line.contentEnd
        }
        let last = candidates[candidates.count - 1]
        let range = first.start..<last.contentEnd
        let newText = output
        guard newText != string(units, range) else { return nil }
        let selectionOut: Range<Int>
        if selection.isEmpty {
            let caret = max(firstPrefixEnd, selection.lowerBound + firstDelta)
            selectionOut = caret..<caret
        } else {
            selectionOut = range.lowerBound..<(range.lowerBound + newText.utf16.count)
        }
        return NoteTextEdit(range: range, replacement: newText, selection: selectionOut)
    }

    private static func lineStart(_ units: [UInt16], _ position: Int) -> Int {
        var index = min(position, units.count)
        while index > 0, units[index - 1] != 0x0A, units[index - 1] != 0x0D { index -= 1 }
        return index
    }

    private static func leading(_ units: [UInt16], _ line: MarkdownSourceScanner.LineBounds) -> Int {
        var count = 0
        while line.start + count < line.contentEnd,
            units[line.start + count] == 0x20 || units[line.start + count] == 0x09
        { count += 1 }
        return count
    }
}
