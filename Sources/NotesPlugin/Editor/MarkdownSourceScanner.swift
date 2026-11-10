import Foundation

/// The pure half of the editor: it reads the Markdown SOURCE as UTF-16 code units (the text the editor stores,
/// markers visible, ADR 0008 addendum 0.2) and answers where the blocks are and which style every run has. Foundation's
/// `AttributedString(markdown:)` drops the markers, so its runs cannot be mapped back to source offsets; this
/// scanner reads the source itself, for the subset the notes use (headings, paragraphs, bullet, numbered and
/// task lists, quotes, fenced code, tables, bold, italic, strikethrough, inline code and inert links).
/// Nothing here follows a link, loads an image or reads HTML: it only classifies characters.
enum MarkdownSourceScanner {
    // MARK: Blocks

    /// The blocks of `units`: runs of lines separated by blank lines; a fenced code block stays one block (blank
    /// lines inside it included, an unterminated fence runs to the end) and is its own block even without blank lines
    /// around it. A block never includes its final line break. Ranges are UTF-16 offsets.
    static func blocks(in units: [UInt16]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start: Int?
        var end = 0
        var fence: Fence?
        var position = 0
        while position < units.count {
            let line = lineRange(in: units, at: position)
            position = line.next
            let content = line.start..<line.contentEnd
            if let open = fence {
                end = line.contentEnd
                if open.isClosed(by: units, line: content) {
                    fence = nil
                    result.append((start ?? content.lowerBound)..<end)
                    start = nil
                }
                continue
            }
            if isBlank(units, content) {
                if let from = start { result.append(from..<end) }
                start = nil
                continue
            }
            if let opened = Fence.opening(in: units, line: content) {
                if let from = start { result.append(from..<end) }
                start = content.lowerBound
                end = line.contentEnd
                fence = opened
                continue
            }
            if start == nil { start = content.lowerBound }
            end = line.contentEnd
        }
        if let from = start { result.append(from..<end) }
        return result
    }

    // MARK: Styles

    /// A run of source with its style; spans may overlap, `runs` merges them.
    struct Span: Equatable {
        var range: Range<Int>
        var style: Style
    }

    struct Style: OptionSet, Hashable {
        let rawValue: UInt16
        static let bold = Style(rawValue: 1 << 0)
        static let italic = Style(rawValue: 1 << 1)
        static let strike = Style(rawValue: 1 << 2)
        /// Inline code: the monospaced face on a tinted background.
        static let code = Style(rawValue: 1 << 3)
        /// Markup characters (`#`, `**`, `>`, a link's brackets and address, fences): shown, in the secondary colour.
        static let marker = Style(rawValue: 1 << 4)
        static let heading1 = Style(rawValue: 1 << 5)
        static let heading2 = Style(rawValue: 1 << 6)
        static let heading3 = Style(rawValue: 1 << 7)
        static let quote = Style(rawValue: 1 << 8)
        /// A list bullet, number or task box.
        static let listMarker = Style(rawValue: 1 << 9)
        /// The text of a link. Styling only: no `link` attribute is ever set, so nothing is clickable.
        static let link = Style(rawValue: 1 << 10)
        /// A line inside a fenced code block, or a table row: the monospaced face.
        static let monospaced = Style(rawValue: 1 << 11)
        static let headings: Style = [.heading1, .heading2, .heading3]
    }

    /// The styled runs of one block, in order and without overlaps; text between spans has the empty style.
    /// Depends on the block's text alone, which is what makes a block-local restyle equal to a full one.
    static func runs(in units: [UInt16], block: Range<Int>) -> [Span] {
        merge(spans(in: units, block: block), over: block)
    }

    static func spans(in units: [UInt16], block: Range<Int>) -> [Span] {
        var spans: [Span] = []
        var fence: Fence?
        var position = block.lowerBound
        while position < block.upperBound {
            let line = lineRange(in: units, at: position)
            position = line.next
            let content = line.start..<min(line.contentEnd, block.upperBound)
            if let open = fence {
                spans.append(Span(range: content, style: .monospaced))
                if open.isClosed(by: units, line: content) {
                    spans.append(Span(range: content, style: .marker))
                    fence = nil
                }
                continue
            }
            if let opened = Fence.opening(in: units, line: content) {
                spans.append(Span(range: content, style: [.monospaced, .marker]))
                fence = opened
                continue
            }
            styleLine(units, content, into: &spans)
        }
        return spans
    }

    // MARK: Lines

    private static func styleLine(_ units: [UInt16], _ line: Range<Int>, into spans: inout [Span]) {
        let prefix = MarkdownLinePrefix.parse(units, line: line)
        var textStart = line.lowerBound
        switch prefix.kind {
        case .heading(let level):
            let style: Style = level == 1 ? .heading1 : level == 2 ? .heading2 : .heading3
            spans.append(Span(range: line, style: style))
            spans.append(Span(range: line.lowerBound..<(line.lowerBound + prefix.length), style: .marker))
            textStart = line.lowerBound + prefix.length
        case .quote:
            spans.append(Span(range: line, style: .quote))
            spans.append(Span(range: line.lowerBound..<(line.lowerBound + prefix.length), style: .marker))
            textStart = line.lowerBound + prefix.length
        case .bullet, .number, .task:
            spans.append(Span(range: line.lowerBound..<(line.lowerBound + prefix.length), style: .listMarker))
            textStart = line.lowerBound + prefix.length
        case .none:
            break
        }
        if isTableRow(units, line) {
            spans.append(Span(range: line, style: .monospaced))
            if isTableRule(units, line) { spans.append(Span(range: line, style: .marker)) }
            return
        }
        inline(units, textStart..<line.upperBound, into: &spans)
    }

    private static func isTableRow(_ units: [UInt16], _ line: Range<Int>) -> Bool {
        var index = line.lowerBound
        while index < line.upperBound, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        return index < line.upperBound && units[index] == 0x7C
    }

    /// `| --- | :---: |`: only pipes, dashes, colons and spaces.
    private static func isTableRule(_ units: [UInt16], _ line: Range<Int>) -> Bool {
        var dashes = 0
        for index in line {
            switch units[index] {
            case 0x7C, 0x3A, 0x20, 0x09: continue
            case 0x2D: dashes += 1
            default: return false
            }
        }
        return dashes > 0
    }

    // MARK: Inline

    /// Inline styles inside one line. Delimiters must hug their text (`**a**`, not `** a **`), `_` does not open
    /// inside a word, a backslash escapes the next character, and nothing spans lines.
    private static func inline(_ units: [UInt16], _ range: Range<Int>, into spans: inout [Span]) {
        var index = range.lowerBound
        while index < range.upperBound {
            let unit = units[index]
            switch unit {
            case 0x5C:  // backslash: skip the escaped character
                index += 2
            case 0x60:  // `
                if let close = codeClose(units, from: index, limit: range.upperBound) {
                    spans.append(Span(range: index..<close.end, style: .code))
                    spans.append(Span(range: index..<(index + close.length), style: .marker))
                    spans.append(Span(range: (close.end - close.length)..<close.end, style: .marker))
                    index = close.end
                } else {
                    index += runLength(units, index, range.upperBound, of: unit)
                }
            case 0x2A, 0x5F:  // * _
                index = emphasis(units, at: index, limit: range.upperBound, into: &spans)
            case 0x7E:  // ~
                if let close = strikeClose(units, from: index, limit: range.upperBound) {
                    spans.append(Span(range: index..<(close + 2), style: .strike))
                    spans.append(Span(range: index..<(index + 2), style: .marker))
                    spans.append(Span(range: close..<(close + 2), style: .marker))
                    inline(units, (index + 2)..<close, into: &spans)
                    index = close + 2
                } else {
                    index += runLength(units, index, range.upperBound, of: unit)
                }
            case 0x5B:  // [
                if let link = linkEnd(units, from: index, limit: range.upperBound) {
                    spans.append(Span(range: (index + 1)..<link.textEnd, style: .link))
                    spans.append(Span(range: index..<(index + 1), style: .marker))
                    spans.append(Span(range: link.textEnd..<link.end, style: .marker))
                    inline(units, (index + 1)..<link.textEnd, into: &spans)
                    index = link.end
                } else {
                    index += 1
                }
            default:
                index += 1
            }
        }
    }

    /// Handles a `*` or `_` run at `index`: strong for two, emphasis for one, both for three. Returns the index
    /// to continue at.
    private static func emphasis(
        _ units: [UInt16], at index: Int, limit: Int, into spans: inout [Span]
    ) -> Int {
        let unit = units[index]
        let run = runLength(units, index, limit, of: unit)
        let after = index + run
        guard after < limit, !isSpace(units[after]) else { return after }
        if unit == 0x5F, index > 0, isWordCharacter(units[index - 1]) { return after }
        guard run <= 3 else { return after }
        let width = run
        // The closing run: the same character, as long as the opening one (one `*` skips a longer run, which is
        // strong text inside the emphasis), preceded by a non-space.
        var search = after
        while search < limit {
            if units[search] == 0x5C {
                search += 2
                continue
            }
            guard units[search] == unit else {
                search += 1
                continue
            }
            let closeRun = runLength(units, search, limit, of: unit)
            let fits = width == 1 ? closeRun == 1 : closeRun >= width
            let intraword = unit == 0x5F && search + closeRun < limit && isWordCharacter(units[search + closeRun])
            if fits, search > after, !isSpace(units[search - 1]), !intraword {
                let style: Style = width == 1 ? .italic : width == 2 ? .bold : [.bold, .italic]
                spans.append(Span(range: index..<(search + width), style: style))
                spans.append(Span(range: index..<after, style: .marker))
                spans.append(Span(range: search..<(search + width), style: .marker))
                inline(units, after..<search, into: &spans)
                return search + width
            }
            search += closeRun
        }
        return after
    }

    private static func codeClose(
        _ units: [UInt16], from index: Int, limit: Int
    ) -> (end: Int, length: Int)? {
        let length = runLength(units, index, limit, of: 0x60)
        var search = index + length
        while search < limit {
            if units[search] == 0x60 {
                let run = runLength(units, search, limit, of: 0x60)
                if run == length { return (search + run, length) }
                search += run
            } else {
                search += 1
            }
        }
        return nil
    }

    private static func strikeClose(_ units: [UInt16], from index: Int, limit: Int) -> Int? {
        guard index + 3 < limit, units[index + 1] == 0x7E, !isSpace(units[index + 2]) else { return nil }
        var search = index + 2
        while search + 1 < limit {
            if units[search] == 0x5C {
                search += 2
            } else if units[search] == 0x7E, units[search + 1] == 0x7E, !isSpace(units[search - 1]) {
                return search
            } else {
                search += 1
            }
        }
        return nil
    }

    /// `[text](address)` on one line: where the text ends and the whole link ends.
    private static func linkEnd(
        _ units: [UInt16], from index: Int, limit: Int
    ) -> (textEnd: Int, end: Int)? {
        var depth = 0
        var search = index
        while search < limit {
            switch units[search] {
            case 0x5C: search += 1
            case 0x5B: depth += 1
            case 0x5D:
                depth -= 1
                if depth == 0 {
                    guard search + 1 < limit, units[search + 1] == 0x28 else { return nil }
                    var close = search + 2
                    while close < limit, units[close] != 0x29 { close += 1 }
                    return close < limit && search > index + 1 ? (search, close + 1) : nil
                }
            default: break
            }
            search += 1
        }
        return nil
    }

    // MARK: Merging

    /// Cuts the spans at every boundary and unions the styles of the spans that cover each piece.
    static func merge(_ spans: [Span], over block: Range<Int>) -> [Span] {
        guard !spans.isEmpty else { return [Span(range: block, style: [])] }
        var points = Set<Int>([block.lowerBound, block.upperBound])
        for span in spans where !span.range.isEmpty {
            points.insert(max(span.range.lowerBound, block.lowerBound))
            points.insert(min(span.range.upperBound, block.upperBound))
        }
        let sorted = points.sorted()
        var result: [Span] = []
        for (from, to) in zip(sorted, sorted.dropFirst()) where from < to {
            var style: Style = []
            for span in spans where span.range.lowerBound <= from && span.range.upperBound >= to {
                style.formUnion(span.style)
            }
            if let last = result.last, last.style == style, last.range.upperBound == from {
                result[result.count - 1].range = last.range.lowerBound..<to
            } else {
                result.append(Span(range: from..<to, style: style))
            }
        }
        return result
    }

    // MARK: Characters and lines

    struct LineBounds {
        var start: Int
        var contentEnd: Int
        var next: Int
    }

    static func lineRange(in units: [UInt16], at position: Int) -> LineBounds {
        var end = position
        while end < units.count, units[end] != 0x0A, units[end] != 0x0D { end += 1 }
        var next = end
        if next < units.count {
            next += units[next] == 0x0D && next + 1 < units.count && units[next + 1] == 0x0A ? 2 : 1
        }
        return LineBounds(start: position, contentEnd: end, next: next)
    }

    static func isBlank(_ units: [UInt16], _ line: Range<Int>) -> Bool {
        line.allSatisfy { units[$0] == 0x20 || units[$0] == 0x09 }
    }

    fileprivate static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

    fileprivate static func isWordCharacter(_ unit: UInt16) -> Bool {
        (unit >= 0x30 && unit <= 0x39) || (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A)
            || unit >= 0x80
    }

    fileprivate static func runLength(_ units: [UInt16], _ index: Int, _ limit: Int, of unit: UInt16) -> Int {
        var length = 0
        while index + length < limit, units[index + length] == unit { length += 1 }
        return length
    }

    /// A code fence: three or more backticks or tildes, indented by spaces or tabs.
    struct Fence {
        var marker: UInt16
        var length: Int

        static func opening(in units: [UInt16], line: Range<Int>) -> Fence? {
            var index = line.lowerBound
            while index < line.upperBound, isSpace(units[index]) { index += 1 }
            guard index < line.upperBound, units[index] == 0x60 || units[index] == 0x7E else { return nil }
            let marker = units[index]
            let length = runLength(units, index, line.upperBound, of: marker)
            guard length >= 3 else { return nil }
            // A backtick fence's info string may not contain a backtick (then it is inline code).
            if marker == 0x60, units[(index + length)..<line.upperBound].contains(0x60) { return nil }
            return Fence(marker: marker, length: length)
        }

        func isClosed(by units: [UInt16], line: Range<Int>) -> Bool {
            var index = line.lowerBound
            while index < line.upperBound, isSpace(units[index]) { index += 1 }
            let run = runLength(units, index, line.upperBound, of: marker)
            guard run >= length else { return false }
            return units[(index + run)..<line.upperBound].allSatisfy(isSpace)
        }
    }
}

/// The block prefix of one source line: a heading's `#`s, a quote's `>`, a list bullet, number or task box.
enum MarkdownLinePrefix {
    enum Kind: Equatable {
        case none
        case heading(level: Int)
        case quote
        case bullet
        case number
        case task(done: Bool)
    }

    struct Parsed: Equatable {
        var kind: Kind
        /// How many characters from the line start the prefix covers, its indent and following space included.
        var length: Int
    }

    static func parse(_ units: [UInt16], line: Range<Int>) -> Parsed {
        var index = line.lowerBound
        while index < line.upperBound, units[index] == 0x20 || units[index] == 0x09 { index += 1 }
        let indent = index - line.lowerBound
        guard index < line.upperBound else { return Parsed(kind: .none, length: 0) }
        let unit = units[index]
        if unit == 0x23 {  // #
            var count = 0
            while index + count < line.upperBound, units[index + count] == 0x23 { count += 1 }
            let after = index + count
            if count <= 6, indent <= 3, after == line.upperBound || units[after] == 0x20 || units[after] == 0x09 {
                var end = after
                while end < line.upperBound, units[end] == 0x20 || units[end] == 0x09 { end += 1 }
                return Parsed(kind: .heading(level: min(count, 3)), length: end - line.lowerBound)
            }
            return Parsed(kind: .none, length: 0)
        }
        if unit == 0x3E, indent <= 3 {  // >
            var end = index + 1
            if end < line.upperBound, units[end] == 0x20 { end += 1 }
            return Parsed(kind: .quote, length: end - line.lowerBound)
        }
        var markerEnd: Int?
        var isNumber = false
        if unit == 0x2D || unit == 0x2A || unit == 0x2B {
            markerEnd = index + 1
        } else if unit >= 0x30, unit <= 0x39 {
            var digits = 0
            while index + digits < line.upperBound, units[index + digits] >= 0x30, units[index + digits] <= 0x39 {
                digits += 1
            }
            if digits <= 9, index + digits < line.upperBound,
                units[index + digits] == 0x2E || units[index + digits] == 0x29
            {
                markerEnd = index + digits + 1
                isNumber = true
            }
        }
        guard let afterMarker = markerEnd, afterMarker < line.upperBound,
            units[afterMarker] == 0x20 || units[afterMarker] == 0x09
        else { return Parsed(kind: .none, length: 0) }
        var end = afterMarker
        while end < line.upperBound, units[end] == 0x20 || units[end] == 0x09 { end += 1 }
        if !isNumber, end + 2 < line.upperBound, units[end] == 0x5B, units[end + 2] == 0x5D,
            units[end + 1] == 0x20 || units[end + 1] == 0x78 || units[end + 1] == 0x58
        {
            let done = units[end + 1] != 0x20
            var boxEnd = end + 3
            if boxEnd == line.upperBound || units[boxEnd] == 0x20 || units[boxEnd] == 0x09 {
                while boxEnd < line.upperBound, units[boxEnd] == 0x20 || units[boxEnd] == 0x09 { boxEnd += 1 }
                return Parsed(kind: .task(done: done), length: boxEnd - line.lowerBound)
            }
        }
        return Parsed(kind: isNumber ? .number : .bullet, length: end - line.lowerBound)
    }
}
