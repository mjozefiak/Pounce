import AppKit

/// Keeps the attributes of the editor's text storage in step with its Markdown source, one block at a time.
///
/// The text is never regenerated: the storage IS the Markdown, and this only sets attributes. After an edit it
/// scans the new text for block and gap boundaries (a cheap pass over the UTF-16 units, no styling), and styles
/// only the segments that did not exist before the edit (a segment that is the same range as before, outside the
/// edit, has the same text and so the same style). A whole-document restyle happens only for a programmatic
/// replacement of the text and when the theme changes (ADR 0008 addendum 0.1: a whole-document parse per
/// keystroke would cost 28 to 43 ms at 50 000 characters).
@MainActor
final class NoteEditorStyler {
    struct Segment: Hashable {
        var range: Range<Int>
        var isBlock: Bool
    }

    /// What the last pass did, for tests and the benchmark.
    struct Report: Equatable {
        var restyledBlocks: Int
        var restyledGaps: Int
        var totalBlocks: Int
    }

    private(set) var theme: NoteEditorTheme
    private(set) var segments: [Segment] = []
    private(set) var lastReport = Report(restyledBlocks: 0, restyledGaps: 0, totalBlocks: 0)

    init(theme: NoteEditorTheme) {
        self.theme = theme
    }

    func setTheme(_ theme: NoteEditorTheme, storage: NSTextStorage) {
        self.theme = theme
        restyleAll(storage)
    }

    func restyleAll(_ storage: NSTextStorage) {
        let units = Self.units(of: storage)
        segments = Self.segments(in: units)
        storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: storage.length))
        var blocks = 0
        for segment in segments where segment.isBlock {
            // Raw has nothing to style: the base attributes already cover the block.
            if theme.mode.stylesBlocks { apply(segment.range, units: units, to: storage) }
            blocks += 1
        }
        lastReport = Report(restyledBlocks: blocks, restyledGaps: 0, totalBlocks: blocks)
    }

    /// After the characters in `edited` (new coordinates) replaced `edited.length - delta` characters.
    func restyle(_ storage: NSTextStorage, edited: NSRange, changeInLength delta: Int) {
        let units = Self.units(of: storage)
        let editStart = edited.location
        let oldEditEnd = edited.location + edited.length - delta
        var unchanged = Set<Segment>()
        for segment in segments {
            if segment.range.upperBound <= editStart {
                unchanged.insert(segment)
            } else if segment.range.lowerBound >= oldEditEnd {
                unchanged.insert(
                    Segment(
                        range: (segment.range.lowerBound + delta)..<(segment.range.upperBound + delta),
                        isBlock: segment.isBlock))
            }
        }
        let fresh = Self.segments(in: units)
        // The edited characters took the attributes next to them; they are reset before their block draws.
        let clamped = NSIntersectionRange(edited, NSRange(location: 0, length: storage.length))
        if clamped.length > 0 { storage.setAttributes(theme.baseAttributes, range: clamped) }
        var blocks = 0
        var gaps = 0
        for segment in fresh where !unchanged.contains(segment) {
            if segment.isBlock {
                if theme.mode.stylesBlocks {
                    apply(segment.range, units: units, to: storage)
                } else {
                    storage.setAttributes(theme.baseAttributes, range: NSRange(segment.range))
                }
                blocks += 1
            } else {
                storage.setAttributes(theme.baseAttributes, range: NSRange(segment.range))
                gaps += 1
            }
        }
        segments = fresh
        lastReport = Report(
            restyledBlocks: blocks, restyledGaps: gaps, totalBlocks: fresh.filter(\.isBlock).count)
    }

    private func apply(_ block: Range<Int>, units: [UInt16], to storage: NSTextStorage) {
        for run in MarkdownSourceScanner.runs(in: units, block: block) where !run.range.isEmpty {
            storage.setAttributes(theme.attributes(for: run.style), range: NSRange(run.range))
        }
    }

    // MARK: Scanning

    static func units(of storage: NSTextStorage) -> [UInt16] {
        let string = storage.string as NSString
        let length = string.length
        return [UInt16](unsafeUninitializedCapacity: length) { buffer, count in
            guard let base = buffer.baseAddress else {
                count = 0
                return
            }
            string.getCharacters(base, range: NSRange(location: 0, length: length))
            count = length
        }
    }

    /// The blocks and the gaps between them, in order, covering the whole text.
    nonisolated static func segments(in units: [UInt16]) -> [Segment] {
        var result: [Segment] = []
        var position = 0
        for block in MarkdownSourceScanner.blocks(in: units) {
            if block.lowerBound > position {
                result.append(Segment(range: position..<block.lowerBound, isBlock: false))
            }
            result.append(Segment(range: block, isBlock: true))
            position = block.upperBound
        }
        if position < units.count { result.append(Segment(range: position..<units.count, isBlock: false)) }
        return result
    }
}

extension NSRange {
    init(_ range: Range<Int>) {
        self.init(location: range.lowerBound, length: range.upperBound - range.lowerBound)
    }
}
