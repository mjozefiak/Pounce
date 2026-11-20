import SwiftUI

/// Lays its children out left to right and starts a new line when one does not fit: the spoken-variant pills of
/// a row and the tokens of the variants field (prototype `.va` and `.inp`, `flex-wrap`).
struct WrappingLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 4
    /// The last child grows to the end of its line (the variants field's text field).
    var lastFillsLine = false

    struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(for sizes: [CGSize], width: CGFloat) -> [Line] {
        var result: [Line] = []
        var line = Line()
        for (index, size) in sizes.enumerated() {
            let extra = line.indices.isEmpty ? 0 : horizontalSpacing
            if !line.indices.isEmpty, line.width + extra + size.width > width {
                result.append(line)
                line = Line()
            }
            line.width += (line.indices.isEmpty ? 0 : horizontalSpacing) + size.width
            line.height = max(line.height, size.height)
            line.indices.append(index)
        }
        if !line.indices.isEmpty { result.append(line) }
        return result
    }

    /// The sizes the lines are broken by; the growing last child counts with its own ideal width.
    private func measure(_ subviews: Subviews, width: CGFloat?) -> [CGSize] {
        subviews.enumerated().map { index, subview in
            let grows = lastFillsLine && index == subviews.count - 1
            return subview.sizeThatFits(.init(width: grows ? nil : width, height: nil))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = measure(subviews, width: width.isFinite ? width : nil)
        let arranged = lines(for: sizes, width: width)
        let height = arranged.map(\.height).reduce(0, +) + CGFloat(max(arranged.count - 1, 0)) * verticalSpacing
        let used = arranged.map(\.width).max() ?? 0
        // A field that fills its line takes the whole width offered, not the width of its content.
        if lastFillsLine, let offered = proposal.width { return CGSize(width: offered, height: height) }
        return CGSize(width: proposal.width.map { _ in min(used, width) } ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews, width: bounds.width)
        var y = bounds.minY
        let arranged = lines(for: sizes, width: bounds.width)
        for (lineIndex, line) in arranged.enumerated() {
            var x = bounds.minX
            for index in line.indices {
                var size = sizes[index]
                if lastFillsLine, lineIndex == arranged.count - 1, index == subviews.count - 1 {
                    size.width = max(size.width, bounds.maxX - x)
                }
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading,
                    proposal: .init(width: size.width, height: size.height))
                x += size.width + horizontalSpacing
            }
            y += line.height + verticalSpacing
        }
    }
}
