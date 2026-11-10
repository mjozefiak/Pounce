import SwiftUI

/// The arithmetic of a wrapping row of controls: which items share a line when each keeps its own ideal width. Pure.
enum WrapMath {
    /// The indices on each line, in order. An item wider than `maxWidth` gets a line to itself.
    static func lines(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let needed = current.isEmpty ? width : used + spacing + width
            if !current.isEmpty, needed > maxWidth {
                lines.append(current)
                current = [index]
                used = width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

/// A row of controls that wraps onto a second line instead of clipping a label ("Rename…" became "Rena…" at the
/// window's narrowest in English, longer in Polish). Every control keeps its ideal size.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = measure(subviews, maxWidth: proposal.width ?? .infinity)
        return CGSize(width: measured.width, height: measured.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = WrapMath.lines(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            let height = line.map { sizes[$0].height }.max() ?? 0
            for index in line {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - sizes[index].height) / 2), proposal: .unspecified)
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
    }

    private func measure(_ subviews: Subviews, maxWidth: CGFloat) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let lines = WrapMath.lines(widths: sizes.map(\.width), maxWidth: maxWidth, spacing: spacing)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for line in lines {
            var lineWidth: CGFloat = 0
            var lineHeight: CGFloat = 0
            for index in line {
                lineWidth += sizes[index].width
                lineHeight = max(lineHeight, sizes[index].height)
            }
            lineWidth += spacing * CGFloat(max(line.count - 1, 0))
            width = max(width, lineWidth)
            height += lineHeight
        }
        height += lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: width, height: height)
    }
}
