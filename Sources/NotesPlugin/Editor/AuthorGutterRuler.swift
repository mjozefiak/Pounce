import AppKit
import LintelKit
import LintelUI

/// The author gutter of the editor (prototype `.gt`): beside every block a short label (AI, You, STT) and a
/// 3 pt bar in the author's colour. It is the editor's vertical ruler, so it scrolls with the text and sits to the
/// left of it, outside the text container. Blocks are `MarkdownBlocks.split` blocks located in the source by
/// `BlockLocator`; only the blocks in the viewport are measured.
@MainActor
final class AuthorGutterRuler: NSRulerView {
    struct Block: Equatable {
        var range: NSRange
        var info: BlockAttributionInfo
    }

    var blocks: [Block] = [] {
        didSet { if blocks != oldValue { needsDisplay = true } }
    }

    /// The Details toggle: bars off draws nothing, the author stays spoken.
    var showsBars = true {
        didSet { if showsBars != oldValue { needsDisplay = true } }
    }

    var textScale: CGFloat = 1 {
        didSet {
            if textScale != oldValue {
                ruleThickness = Self.thickness * textScale
                needsDisplay = true
            }
        }
    }

    /// 4.2 em of the prototype's 12.5 pt root plus the 6 pt the text keeps from the bar.
    nonisolated static let thickness: CGFloat = 4.2 * 12.5 + 6

    private(set) var drawn: [(info: BlockAttributionInfo, rect: NSRect)] = []

    /// `client` is the text view the bars sit beside (a ruler draws against its client view).
    init(scrollView: NSScrollView, client: NSView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = client
        ruleThickness = Self.thickness
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var isOpaque: Bool { false }

    /// No ruler background and no separator line (the default `NSRulerView` draws both): the window's own
    /// background shows through and only the bars are drawn.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        drawn = []
        guard let textView = clientView as? NSTextView, let layout = textView.textLayoutManager,
            let content = layout.textContentManager
        else { return }
        let viewport = layout.textViewportLayoutController.viewportRange
        let origin = textView.textContainerOrigin
        let labelFont = NSFont.monospacedSystemFont(ofSize: 9.25 * textScale, weight: .regular)
        for block in blocks {
            guard let range = Self.textRange(block.range, in: content),
                Self.intersects(range, viewport)
            else { continue }
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                top = min(top, frame.minY)
                bottom = max(bottom, frame.maxY)
                return true
            }
            guard top <= bottom else { continue }
            let start = convert(NSPoint(x: 0, y: top + origin.y), from: textView).y
            let end = convert(NSPoint(x: 0, y: bottom + origin.y), from: textView).y
            let band = NSRect(x: 0, y: min(start, end), width: bounds.width, height: abs(end - start))
            drawn.append((block.info, band))
            guard showsBars else { continue }
            draw(block.info, in: band, labelFont: labelFont)
        }
    }

    private func draw(_ info: BlockAttributionInfo, in band: NSRect, labelFont: NSFont) {
        let barWidth: CGFloat = 3
        let barX = bounds.width - barWidth - 3 * textScale
        let bar = NSRect(
            x: barX, y: band.minY + 3, width: barWidth, height: max(band.height - 6, barWidth))
        let color = Self.color(for: info.author)
        color.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        let text = info.author.gutterText as NSString
        guard text.length > 0 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: LintelBrand.secondaryTextColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: barX - 7 * textScale - size.width, y: band.minY + 5 * textScale), withAttributes: attributes)
    }

    static func color(for author: NoteAuthor) -> NSColor {
        switch author {
        case .agent: LintelBrand.accentColor
        case .human: LintelBrand.inkColor
        default: LintelBrand.secondaryTextColor.withAlphaComponent(0.5)
        }
    }

    private static func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
        guard let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }

    private static func intersects(_ range: NSTextRange, _ viewport: NSTextRange?) -> Bool {
        guard let viewport else { return true }
        return range.location.compare(viewport.endLocation) == .orderedAscending
            && range.endLocation.compare(viewport.location) != .orderedAscending
    }

    // MARK: Accessibility

    /// One element per block in view: the author in words (and the mark), in reading order. The bars may be off,
    /// the authors are still spoken.
    override func accessibilityChildren() -> [Any]? {
        drawn.map { entry in
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(entry.info.spokenLabel)
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(entry.rect)
            return element
        }
    }
}
