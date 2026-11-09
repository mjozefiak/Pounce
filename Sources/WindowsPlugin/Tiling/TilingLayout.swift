import CoreGraphics
import Foundation
import LintelKit

/// The space tiling leaves: between neighbouring windows and around the whole set (spec: "Gaps (inner, outer)
/// are settings").
struct TilingGaps: Equatable, Sendable {
    var inner: CGFloat
    var outer: CGFloat

    static let none = TilingGaps(inner: 0, outer: 0)

    init(inner: CGFloat, outer: CGFloat) {
        self.inner = max(0, inner)
        self.outer = max(0, outer)
    }
}

/// The frames of a tiling tree: pure geometry, no I/O (spec: `TilingLayout.frames(tree, area, gaps)`).
///
/// A container splits its rectangle along its axis in proportion to the weights of its children, after the
/// inner gaps are taken out (the gaps shrink when there are so many windows that they would take more than a
/// quarter of the length). Edges are rounded to whole points, and each child starts exactly one gap after the
/// previous one ended, so tiles never overlap and the outer tiles reach the outer gap exactly.
enum TilingLayout {
    static func frames(_ tree: TilingTree, area: CGRect, gaps: TilingGaps) -> [WindowID: CGRect] {
        let dx = min(gaps.outer, area.width / 2)
        let dy = min(gaps.outer, area.height / 2)
        let inner = area.insetBy(dx: dx, dy: dy)
        var result: [WindowID: CGRect] = [:]
        layout(tree.root, in: inner, gap: gaps.inner, into: &result)
        return result
    }

    private static func layout(
        _ container: TilingContainer, in rect: CGRect, gap: CGFloat, into result: inout [WindowID: CGRect]
    ) {
        let count = container.children.count
        guard count > 0 else { return }
        let horizontal = container.orientation == .horizontal
        let length = horizontal ? rect.width : rect.height
        let origin = horizontal ? rect.minX : rect.minY
        // Many windows must not turn the gaps into the whole length: the gaps together take at most a quarter.
        let gap = count > 1 ? min(gap, length / CGFloat(4 * (count - 1))) : gap
        let available = max(0, length - gap * CGFloat(count - 1))
        let weights = container.children.map { TilingTree.sanitized($0.weight) }
        let total = weights.reduce(0, +)
        var consumed: Double = 0
        for (index, child) in container.children.enumerated() {
            let lower = origin + CGFloat(consumed / total) * available + CGFloat(index) * gap
            consumed += weights[index]
            let upper = origin + CGFloat(consumed / total) * available + CGFloat(index) * gap
            let low = lower.rounded()
            // The last child ends exactly on the edge, whatever the rounding did before it.
            let high = index == count - 1 ? (origin + length).rounded() : upper.rounded()
            let tile =
                horizontal
                ? CGRect(x: low, y: rect.minY, width: max(0, high - low), height: rect.height)
                : CGRect(x: rect.minX, y: low, width: rect.width, height: max(0, high - low))
            switch child.node {
            case .window(let id):
                result[id] = tile
            case .container(let inner):
                layout(inner, in: tile, gap: gap, into: &result)
            }
        }
    }
}
