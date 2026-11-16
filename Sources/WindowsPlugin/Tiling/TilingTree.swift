import Foundation
import LintelKit

/// The way a container lays its children out: side by side or one above the other.
enum TilingOrientation: String, Codable, Sendable, CaseIterable {
    case horizontal
    case vertical

    var flipped: TilingOrientation { self == .horizontal ? .vertical : .horizontal }
}

extension LayoutDirection {
    /// The orientation of the container whose children this direction walks along.
    var axis: TilingOrientation {
        switch self {
        case .left, .right: .horizontal
        case .up, .down: .vertical
        }
    }

    /// The change of a child index: toward the end of the container (+1) or its start (-1).
    var step: Int {
        switch self {
        case .left, .up: -1
        case .right, .down: 1
        }
    }
}

/// One child of a container: a window or a nested container, with a weight (its share of the container along
/// the container's axis, relative to the weights of its siblings).
struct TilingChild: Equatable, Sendable {
    var weight: Double
    var node: TilingNode
}

enum TilingNode: Equatable, Sendable {
    case window(WindowID)
    case container(TilingContainer)
}

struct TilingContainer: Equatable, Sendable {
    var orientation: TilingOrientation
    var children: [TilingChild]

    init(orientation: TilingOrientation, children: [TilingChild] = []) {
        self.orientation = orientation
        self.children = children
    }
}

/// The tiling state of one workspace (spec: Proposed Solution, "Tiling layout"; pure value, no I/O). The root is
/// always a container; `normalize()` keeps the tree canonical:
/// - weights are finite and positive,
/// - no container is empty or holds a single child (except the root, which may hold one window),
/// - a container never has a child container of its own orientation (the two are merged), so orientations
///   alternate down every branch.
struct TilingTree: Equatable, Sendable {
    var root: TilingContainer

    init(orientation: TilingOrientation = .horizontal) {
        root = TilingContainer(orientation: orientation)
    }

    init(root: TilingContainer) {
        self.root = root
        normalize()
    }

    var isEmpty: Bool { root.children.isEmpty }

    /// Every window, depth first, in layout order (left to right, top to bottom).
    var windows: [WindowID] { root.windows }

    func contains(_ window: WindowID) -> Bool { path(to: window) != nil }

    /// A tree needs no windows to have a root orientation; an empty or one-window tree takes it over freely.
    var rootOrientation: TilingOrientation { root.orientation }

    // MARK: Insert and remove

    /// Inserts `window` right after `anchor` in the container that holds the anchor, with the average weight of
    /// its new siblings; at the end of the root when there is no anchor in the tree. A window already in the tree
    /// stays where it is.
    mutating func insert(_ window: WindowID, after anchor: WindowID? = nil) {
        guard !contains(window) else { return }
        if let anchor, let path = path(to: anchor), let index = path.last {
            root.withContainer(at: path.dropLast()) { container in
                let weight = container.averageWeight
                container.children.insert(
                    TilingChild(weight: weight, node: .window(window)), at: min(index + 1, container.children.count))
            }
        } else {
            let weight = root.averageWeight
            root.children.append(TilingChild(weight: weight, node: .window(window)))
        }
        normalize()
    }

    /// Removes a window. Containers that become empty disappear and a container with one child is replaced by
    /// that child. Returns whether the window was in the tree.
    @discardableResult
    mutating func remove(_ window: WindowID) -> Bool {
        guard let path = path(to: window), let index = path.last else { return false }
        root.withContainer(at: path.dropLast()) { $0.children.remove(at: index) }
        normalize()
        return true
    }

    // MARK: Paths

    /// The child indices from the root down to a window: every index but the last picks a nested container, the
    /// last one is the window's place in its parent.
    func path(to window: WindowID) -> [Int]? { root.path(to: window) }

    // MARK: Canonical form

    mutating func normalize() {
        root = Self.normalized(root)
        // A root whose only child is a container is that container.
        while root.children.count == 1, case .container(let only) = root.children[0].node {
            root = only
        }
    }

    private static func normalized(_ container: TilingContainer) -> TilingContainer {
        var result = TilingContainer(orientation: container.orientation)
        for child in container.children {
            result.children.append(contentsOf: flatten(child.node, weight: sanitized(child.weight), into: result))
        }
        return result
    }

    /// The children a node contributes to a parent: nothing, the node itself, its only child, or (for a nested
    /// container of the parent's orientation) its children with the weights scaled to the node's weight.
    private static func flatten(_ node: TilingNode, weight: Double, into parent: TilingContainer)
        -> [TilingChild]
    {
        switch node {
        case .window:
            return [TilingChild(weight: weight, node: node)]
        case .container(let inner):
            let cleaned = normalized(inner)
            switch cleaned.children.count {
            case 0:
                return []
            case 1:
                return flatten(cleaned.children[0].node, weight: weight, into: parent)
            default:
                guard cleaned.orientation == parent.orientation else {
                    return [TilingChild(weight: weight, node: .container(cleaned))]
                }
                let total = cleaned.children.reduce(0) { $0 + $1.weight }
                return cleaned.children.map {
                    TilingChild(weight: weight * $0.weight / total, node: $0.node)
                }
            }
        }
    }

    static func sanitized(_ weight: Double) -> Double {
        weight.isFinite && weight > 0 ? weight : 1
    }
}

extension TilingContainer {
    var windows: [WindowID] {
        children.flatMap { child -> [WindowID] in
            switch child.node {
            case .window(let id): [id]
            case .container(let inner): inner.windows
            }
        }
    }

    /// The mean weight of the children, or 1 without any: what a new child gets.
    var averageWeight: Double {
        guard !children.isEmpty else { return 1 }
        return children.reduce(0) { $0 + $1.weight } / Double(children.count)
    }

    var totalWeight: Double { children.reduce(0) { $0 + $1.weight } }

    /// The number of windows in this container and below.
    var windowCount: Int { windows.count }

    func path(to window: WindowID) -> [Int]? {
        for (index, child) in children.enumerated() {
            switch child.node {
            case .window(let id):
                if id == window { return [index] }
            case .container(let inner):
                if let rest = inner.path(to: window) { return [index] + rest }
            }
        }
        return nil
    }

    /// Runs `body` on the container reached by following `prefix` (an empty prefix is this container). A prefix
    /// that does not lead to a container does nothing.
    mutating func withContainer(at prefix: ArraySlice<Int>, _ body: (inout TilingContainer) -> Void) {
        guard let first = prefix.first else {
            body(&self)
            return
        }
        guard children.indices.contains(first), case .container(var inner) = children[first].node else { return }
        inner.withContainer(at: prefix.dropFirst(), body)
        children[first].node = .container(inner)
    }

    /// The container reached by following `prefix`.
    func container(at prefix: ArraySlice<Int>) -> TilingContainer? {
        guard let first = prefix.first else { return self }
        guard children.indices.contains(first), case .container(let inner) = children[first].node else {
            return nil
        }
        return inner.container(at: prefix.dropFirst())
    }
}
