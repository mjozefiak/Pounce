import CoreGraphics
import Foundation
import LintelKit

/// Focus and move by direction in a tiling tree (spec Q7; pure, no I/O).
enum TilingNavigation {
    /// The size of the nominal area the tree is laid out in to compare tiles; only proportions matter.
    private static let nominal = CGRect(x: 0, y: 0, width: 10_000, height: 10_000)
    private static let epsilon: CGFloat = 1

    // MARK: Focus

    /// The window to focus when moving in `direction` from `window`: the nearest tile that lies beyond the
    /// window's edge and overlaps it across the direction. Among several, the one that contains the middle of
    /// the window, then the one that overlaps most, then the first in layout order. `nil` at the edge.
    static func neighbour(of window: WindowID, _ direction: TilingDirection, in tree: TilingTree) -> WindowID? {
        let frames = TilingLayout.frames(tree, area: nominal, gaps: .none)
        guard let source = frames[window] else { return nil }
        let order = tree.windows
        let horizontal = direction.axis == .horizontal
        var best: (id: WindowID, key: [Double])?
        for (index, id) in order.enumerated() where id != window {
            guard let frame = frames[id] else { continue }
            let distance: CGFloat
            switch direction {
            case .right: distance = frame.minX - source.maxX
            case .left: distance = source.minX - frame.maxX
            case .down: distance = frame.minY - source.maxY
            case .up: distance = source.minY - frame.maxY
            }
            guard distance >= -epsilon else { continue }
            let low = horizontal ? max(frame.minY, source.minY) : max(frame.minX, source.minX)
            let high = horizontal ? min(frame.maxY, source.maxY) : min(frame.maxX, source.maxX)
            let overlap = high - low
            guard overlap > epsilon else { continue }
            let middle = horizontal ? source.midY : source.midX
            let spans = horizontal ? (frame.minY...frame.maxY) : (frame.minX...frame.maxX)
            let key: [Double] = [
                Double(max(0, distance).rounded()), spans.contains(middle) ? 0 : 1, -Double(overlap), Double(index),
            ]
            if best == nil || key.lexicographicallyPrecedes(best?.key ?? key) { best = (id, key) }
        }
        return best?.id
    }

    // MARK: Move

    /// The tree after moving `window` in `direction`, or `nil` when nothing would change. Starting at the
    /// window's own container and going outwards, the first container that splits along the direction decides:
    /// - the window is a direct child and the next sibling is a window: the two swap places;
    /// - the next sibling is a container: the window moves into it, at its near edge;
    /// - the window sits in a nested container: it leaves it and lands beside it, on the side of the direction.
    /// At the edge of the outermost container nothing happens.
    static func move(_ window: WindowID, _ direction: TilingDirection, in tree: TilingTree) -> TilingTree? {
        guard let path = tree.path(to: window), !path.isEmpty else { return nil }
        let step = direction.step
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let prefix = path[0..<depth]
            guard let container = tree.root.container(at: prefix), container.orientation == direction.axis else {
                continue
            }
            let index = path[depth]
            var next = tree
            if depth == path.count - 1 {
                let target = index + step
                guard container.children.indices.contains(target) else { continue }
                switch container.children[target].node {
                case .window:
                    next.root.withContainer(at: prefix) {
                        let moved = $0.children[index].node
                        $0.children[index].node = $0.children[target].node
                        $0.children[target].node = moved
                    }
                case .container:
                    next.root.withContainer(at: prefix) { parent in
                        let child = parent.children.remove(at: index)
                        let adjusted = step > 0 ? index : index - 1
                        guard case .container(var inner) = parent.children[adjusted].node else { return }
                        let at = step > 0 ? 0 : inner.children.count
                        inner.children.insert(
                            TilingChild(weight: inner.averageWeight, node: child.node), at: at)
                        parent.children[adjusted].node = .container(inner)
                    }
                }
            } else {
                // Take the window out of the nested branch, then put it beside the branch.
                var taken: TilingNode?
                next.root.withContainer(at: path[0..<(path.count - 1)]) { owner in
                    taken = owner.children.remove(at: path[path.count - 1]).node
                }
                guard let taken else { continue }
                next.root.withContainer(at: prefix) { parent in
                    let at = step > 0 ? index + 1 : index
                    parent.children.insert(
                        TilingChild(weight: parent.averageWeight, node: taken), at: min(at, parent.children.count))
                }
            }
            next.normalize()
            return next == tree ? nil : next
        }
        return nil
    }
}
