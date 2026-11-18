import CoreGraphics
import Foundation
import LintelKit

/// Adopting a resize the user made with the mouse (pure). The window's new frame is compared with the tile the
/// layout gave it, edge by edge; the share an edge moved is taken from, or given to, the siblings on that side
/// of the nearest container along that axis (AeroSpace's rule: the node changes by the whole difference, each
/// sibling on that side by an equal part of it).
extension TilingTree {
    /// An edge that moved by no more than this many points is not a resize (apps round, and a move is not one).
    static let userResizeThreshold: CGFloat = 5

    private enum Edge: CaseIterable {
        case left, right, top, bottom

        var axis: TilingOrientation { self == .left || self == .right ? .horizontal : .vertical }
        /// Toward the end of the container (+1) or its start (-1).
        var side: Int { self == .right || self == .bottom ? 1 : -1 }

        func position(_ rect: CGRect) -> CGFloat {
            switch self {
            case .left: rect.minX
            case .right: rect.maxX
            case .top: rect.minY
            case .bottom: rect.maxY
            }
        }
    }

    /// Takes `frame` (where the user left the window) as the new size of `window`, whose tile was `tiles[window]`;
    /// `tiles` holds the tile of every window of the tree and gives the pixel length of each subtree. Returns
    /// whether any weight changed. An edge with no sibling on its side, a move without a size change and a
    /// difference the minimum share does not allow are ignored (the caller's settle step puts the window back).
    @discardableResult
    mutating func adopt(frame: CGRect, of window: WindowID, tiles: [WindowID: CGRect]) -> Bool {
        guard let tile = tiles[window], let path = path(to: window), frame.isFinite, tile.isFinite else {
            return false
        }
        var changed = false
        for axis in [TilingOrientation.horizontal, .vertical] {
            let edges = Edge.allCases.filter { $0.axis == axis }
            let moves = edges.map { $0.position(frame) - $0.position(tile) }
            let threshold = Self.userResizeThreshold
            // Both edges moved the same way: the window was moved, not resized.
            if moves.allSatisfy({ abs($0) > threshold }), abs(moves[0] - moves[1]) <= threshold { continue }
            for (edge, move) in zip(edges, moves) where abs(move) > threshold {
                // Growth in points: the right and bottom edges grow the window by moving toward +, the others by
                // moving toward -.
                let growth = Double(move) * Double(edge.side)
                if adoptEdge(edge, growth: growth, path: path, tiles: tiles) { changed = true }
            }
        }
        return changed
    }

    private mutating func adoptEdge(_ edge: Edge, growth: Double, path: [Int], tiles: [WindowID: CGRect]) -> Bool {
        guard growth.isFinite else { return false }
        for depth in stride(from: path.count - 1, through: 0, by: -1) {
            let prefix = path[0..<depth]
            guard let container = root.container(at: prefix), container.orientation == edge.axis else { continue }
            let index = path[depth]
            let siblings = edge.side > 0 ? Array((index + 1)..<container.children.count) : Array(0..<index)
            guard !siblings.isEmpty else { continue }
            let points = Self.length(of: container.children[index].node, along: edge.axis, tiles: tiles)
            guard points > 0 else { return false }
            var changed = false
            root.withContainer(at: prefix) { parent in
                changed = Self.redistribute(&parent, node: index, siblings: siblings, growth: growth, points: points)
            }
            return changed
        }
        return false
    }

    /// Moves `growth` points worth of weight between `node` and `siblings` (equal parts), keeping the sum of the
    /// weights and every weight at or above the minimum share.
    private static func redistribute(
        _ parent: inout TilingContainer, node: Int, siblings: [Int], growth: Double, points: Double
    ) -> Bool {
        var weights = parent.children.map { sanitized($0.weight) }
        let total = weights.reduce(0, +)
        let floor = minimumShare(siblings: weights.count) * total
        let wanted = abs(growth) * weights[node] / points
        let before = weights
        if growth > 0 {
            // The siblings give; each only down to the floor (a weight already below it is not made smaller).
            let given = take(wanted, from: siblings, weights: &weights, floor: floor)
            weights[node] += given
        } else {
            let available = max(0, weights[node] - min(floor, weights[node]))
            let amount = min(wanted, available)
            weights[node] -= amount
            for sibling in siblings { weights[sibling] += amount / Double(siblings.count) }
        }
        guard weights != before else { return false }
        for position in parent.children.indices { parent.children[position].weight = weights[position] }
        return true
    }

    /// Takes up to `amount` from `indices`, equally, none below `floor`; returns what was taken.
    private static func take(_ amount: Double, from indices: [Int], weights: inout [Double], floor: Double) -> Double {
        var remaining = amount
        var open = indices.filter { weights[$0] > floor }
        while remaining > 1e-12, !open.isEmpty {
            let part = remaining / Double(open.count)
            var spent = 0.0
            for index in open {
                let taken = min(part, weights[index] - floor)
                weights[index] -= taken
                spent += taken
            }
            remaining -= spent
            open = open.filter { weights[$0] > floor + 1e-12 }
            if spent <= 1e-12 { break }
        }
        return amount - remaining
    }

    /// The length of a subtree along `axis`, from the tiles of its windows.
    private static func length(of node: TilingNode, along axis: TilingOrientation, tiles: [WindowID: CGRect]) -> Double
    {
        let windows: [WindowID]
        switch node {
        case .window(let id): windows = [id]
        case .container(let inner): windows = inner.windows
        }
        let rects = windows.compactMap { tiles[$0] }
        guard let first = rects.first else { return 0 }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        return Double(axis == .horizontal ? union.width : union.height)
    }
}

extension CGRect {
    fileprivate var isFinite: Bool { !isNull && !isInfinite && origin.x.isFinite && size.width.isFinite }
}
