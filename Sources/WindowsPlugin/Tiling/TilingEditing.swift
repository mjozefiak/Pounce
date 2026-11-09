import Foundation
import LintelKit

/// Resize, join, toggle orientation and balance (spec Q7; pure). Every operation keeps the tree canonical and
/// reports whether it changed anything.
extension TilingTree {
    /// The smallest share of a container a window can be resized to: a tenth, or half of an equal share when
    /// there are more than five siblings.
    static func minimumShare(siblings count: Int) -> Double {
        min(0.1, 0.5 / Double(max(1, count)))
    }

    /// How much one resize command moves, as a share of the container.
    static let resizeStep = 0.05

    // MARK: Resize

    /// Grows (`delta` > 0) or shrinks (`delta` < 0) the window by `delta` of its container along the container's
    /// axis. The window's own container is used when it has siblings, otherwise the nearest one around it that
    /// does. The share comes from (or goes to) the next sibling, or the previous one for the last child. Shares
    /// always sum to one and a sibling never drops below `minimumShare` (a share already below it is never made
    /// smaller).
    @discardableResult
    mutating func resize(_ window: WindowID, by delta: Double) -> Bool {
        guard delta != 0, delta.isFinite, let path = path(to: window) else { return false }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let prefix = path[0..<depth]
            guard let container = root.container(at: prefix), container.children.count > 1 else { continue }
            let index = path[depth]
            let neighbour = index + 1 < container.children.count ? index + 1 : index - 1
            var changed = false
            root.withContainer(at: prefix) { parent in
                let total = parent.totalWeight
                var shares = parent.children.map { TilingTree.sanitized($0.weight) / total }
                let floor = TilingTree.minimumShare(siblings: shares.count)
                let amount: Double
                if delta > 0 {
                    amount = min(delta, max(0, shares[neighbour] - min(floor, shares[neighbour])))
                } else {
                    amount = -min(-delta, max(0, shares[index] - min(floor, shares[index])))
                }
                shares[index] += amount
                shares[neighbour] -= amount
                for position in parent.children.indices { parent.children[position].weight = shares[position] }
                changed = amount != 0
            }
            return changed
        }
        return false
    }

    // MARK: Join

    /// Puts the window and its neighbour in `direction` into a new container whose orientation is the opposite
    /// of their parent's (so the two end up stacked across the old line). When the window has no neighbour
    /// there, the container around it joins the neighbour of that container instead.
    @discardableResult
    mutating func join(_ window: WindowID, _ direction: TilingDirection) -> Bool {
        guard let path = path(to: window) else { return false }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let prefix = path[0..<depth]
            guard let container = root.container(at: prefix), container.orientation == direction.axis else {
                continue
            }
            let index = path[depth]
            let target = index + direction.step
            guard container.children.indices.contains(target) else { continue }
            root.withContainer(at: prefix) { parent in
                let low = min(index, target)
                let first = parent.children[low]
                let second = parent.children[low + 1]
                let merged = TilingContainer(
                    orientation: parent.orientation.flipped,
                    children: [
                        TilingChild(weight: 1, node: first.node), TilingChild(weight: 1, node: second.node),
                    ])
                parent.children.replaceSubrange(
                    low...(low + 1),
                    with: [TilingChild(weight: first.weight + second.weight, node: .container(merged))])
            }
            normalize()
            return true
        }
        return false
    }

    // MARK: Orientation

    /// Flips the orientation of the container that holds the window (the root when the window is a direct child
    /// of it).
    @discardableResult
    mutating func toggleOrientation(of window: WindowID) -> Bool {
        guard let path = path(to: window) else { return false }
        root.withContainer(at: path.dropLast()) { $0.orientation = $0.orientation.flipped }
        normalize()
        return true
    }

    /// Makes `orientation` the root's, flipping every container below it as well so the shape of the tree stays.
    mutating func setRootOrientation(_ orientation: TilingOrientation) {
        guard root.orientation != orientation else { return }
        root = Self.flipped(root)
        normalize()
    }

    private static func flipped(_ container: TilingContainer) -> TilingContainer {
        TilingContainer(
            orientation: container.orientation.flipped,
            children: container.children.map { child in
                switch child.node {
                case .window: child
                case .container(let inner): TilingChild(weight: child.weight, node: .container(flipped(inner)))
                }
            })
    }

    // MARK: Balance

    /// Gives every tile the same share: all weights become one (orientations alternate, so equal weights mean
    /// equal windows).
    mutating func balance() {
        root = Self.balanced(root)
    }

    private static func balanced(_ container: TilingContainer) -> TilingContainer {
        TilingContainer(
            orientation: container.orientation,
            children: container.children.map { child in
                switch child.node {
                case .window: TilingChild(weight: 1, node: child.node)
                case .container(let inner): TilingChild(weight: 1, node: .container(balanced(inner)))
                }
            })
    }
}
