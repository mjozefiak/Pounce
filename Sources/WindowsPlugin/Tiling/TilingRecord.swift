import Foundation
import LintelKit

/// The JSON shape of one workspace's tiling tree in `state.json` (`workspaces[n].tiling`, spec: Data Model):
/// `{"orientation":"horizontal","children":[{"weight":1,"window":{...}},{"weight":2,"container":{...}}]}`.
/// Window ids are plain numbers; no titles, no bundle ids.
struct TilingRecord: Codable, Equatable {
    struct Child: Codable, Equatable {
        var weight: Double
        var window: WindowID?
        var container: TilingRecord?
    }

    /// The deepest nesting accepted when reading; a deeper file is not trusted (and a real tree never gets near).
    static let maximumDepth = 16

    var orientation: TilingOrientation
    var children: [Child]

    init(orientation: TilingOrientation, children: [Child]) {
        self.orientation = orientation
        self.children = children
    }

    init(_ tree: TilingTree) {
        self.init(tree.root)
    }

    private init(_ container: TilingContainer) {
        orientation = container.orientation
        children = container.children.map { child in
            switch child.node {
            case .window(let id): Child(weight: child.weight, window: id, container: nil)
            case .container(let inner): Child(weight: child.weight, window: nil, container: TilingRecord(inner))
            }
        }
    }

    /// The tree this record describes, or `nil` when it nests too deeply or a child has neither a window nor a
    /// container. The tree is normalised, so a hand-edited file cannot produce a shape the engine never makes.
    var tree: TilingTree? {
        guard let root = container(depth: 0) else { return nil }
        return TilingTree(root: root)
    }

    private func container(depth: Int) -> TilingContainer? {
        guard depth < Self.maximumDepth else { return nil }
        var result = TilingContainer(orientation: orientation)
        for child in children {
            switch (child.window, child.container) {
            case (.some(let id), nil):
                result.children.append(TilingChild(weight: child.weight, node: .window(id)))
            case (nil, .some(let inner)):
                guard let nested = inner.container(depth: depth + 1) else { return nil }
                result.children.append(TilingChild(weight: child.weight, node: .container(nested)))
            default:
                return nil
            }
        }
        return result
    }
}
