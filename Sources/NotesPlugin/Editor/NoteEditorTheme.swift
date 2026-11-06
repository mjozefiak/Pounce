import AppKit
import LintelUI

/// The editor's look, built on the brand tokens (`LintelBrand`) and the text size: the system font at the body
/// size, the markup characters in the secondary colour, the accent on list markers and links, the tinted
/// well behind inline code. Prototype `.bd` (1.04 em text, 1.6 line height, h2 1.3 em); the sizes of the other
/// headings are not in the prototype and follow the same ratio.
@MainActor
final class NoteEditorTheme {
    typealias Attributes = [NSAttributedString.Key: Any]

    /// The prototype's body size is 1.04 em of the 12.5 pt root: 13 pt, the macOS body size.
    nonisolated static let lineHeightMultiple: CGFloat = 1.33
    nonisolated static let headingScale: [CGFloat] = [1.6, 1.3, 1.12]

    let textSize: TextSize
    private var cache: [MarkdownSourceScanner.Style: Attributes] = [:]

    init(textSize: TextSize) {
        self.textSize = textSize
    }

    var bodyPointSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize * textSize.scale }

    var baseAttributes: Attributes { attributes(for: []) }

    /// The attributes of a run with `style`: a pure function of the style, so equal styles look equal.
    func attributes(for style: MarkdownSourceScanner.Style) -> Attributes {
        if let cached = cache[style] { return cached }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Self.lineHeightMultiple
        var size = bodyPointSize
        var bold = style.contains(.bold)
        if style.contains(.heading1) {
            size *= Self.headingScale[0]
            bold = true
        } else if style.contains(.heading2) {
            size *= Self.headingScale[1]
            bold = true
        } else if style.contains(.heading3) {
            size *= Self.headingScale[2]
            bold = true
        }
        var color = LintelBrand.inkColor
        var result: Attributes = [:]
        if style.contains(.marker) || style.contains(.quote) { color = LintelBrand.secondaryTextColor }
        if style.contains(.listMarker) || style.contains(.link) { color = LintelBrand.accentTextColor }
        if style.contains(.code) || style.contains(.monospaced) {
            result[.font] = monospaced(size: size * 0.92, bold: bold)
        } else {
            result[.font] = proportional(size: size, bold: bold, italic: style.contains(.italic))
        }
        if style.contains(.code) { result[.backgroundColor] = LintelBrand.fillColor }
        if style.contains(.strike) { result[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        result[.foregroundColor] = color
        result[.paragraphStyle] = paragraph
        cache[style] = result
        return result
    }

    private func proportional(size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        guard italic else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    private func monospaced(size: CGFloat, bold: Bool) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
