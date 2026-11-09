import CoreGraphics
import Foundation
import LintelKit

extension TilingTree: LayoutStateValue {}

/// Auto-tile: an i3/AeroSpace-style tree of split containers per workspace (state kind `tiling`).
struct TilingStrategy: LayoutStrategy {
    var kind: LayoutKind { .tiling }

    func arrange(_ input: LayoutInput) -> LayoutArrangement {
        let layout = input.resolved
        let wanted = Set(input.windows)
        var tree = input.state?.as(TilingTree.self) ?? TilingTree(orientation: layout.rootOrientation)
        // Windows that are gone, floating or moved away leave the tree.
        for id in tree.windows where !wanted.contains(id) { tree.remove(id) }
        if tree.windows.count <= 1 { tree.root.orientation = layout.rootOrientation }
        // New windows enter after the focused window (or the one focused before it), several in join order.
        var anchor: WindowID?
        for id in input.windows where !tree.contains(id) {
            if anchor == nil {
                anchor = [input.focused, input.previousFocus].lazy.compactMap { $0 }
                    .first { $0 != id && tree.contains($0) }
            }
            tree.insert(id, after: anchor)
            anchor = id
        }
        return LayoutArrangement(
            state: AnyLayoutState(tree), frames: TilingLayout.frames(tree, area: input.area, gaps: layout.gaps),
            hints: input.hints)
    }

    func perform(_ command: LayoutCommand, on window: WindowID, _ input: LayoutInput) -> LayoutEdit? {
        guard let tree = input.state?.as(TilingTree.self) else { return nil }
        var next = tree
        switch command.id {
        case "focus":
            guard let direction = command.direction,
                let target = TilingNavigation.neighbour(of: window, direction, in: tree)
            else { return nil }
            return LayoutEdit(state: AnyLayoutState(tree), focus: target, hints: input.hints)
        case "move":
            guard let direction = command.direction, let moved = TilingNavigation.move(window, direction, in: tree)
            else { return nil }
            next = moved
        case LayoutCommand.resizeID:
            guard let delta = command.payload(as: Double.self), next.resize(window, by: delta) else { return nil }
        case LayoutCommand.joinID:
            guard let direction = command.direction, next.join(window, direction) else { return nil }
        case LayoutCommand.toggleOrientationID:
            guard next.toggleOrientation(of: window) else { return nil }
        case LayoutCommand.balanceID:
            next.balance()
            if next == tree { return nil }
        default:
            return nil
        }
        return LayoutEdit(state: AnyLayoutState(next), focus: nil, hints: input.hints)
    }

    func removing(_ window: WindowID, from state: AnyLayoutState) -> AnyLayoutState {
        guard var tree = state.as(TilingTree.self) else { return state }
        tree.remove(window)
        return AnyLayoutState(tree)
    }

    func encode(_ state: AnyLayoutState) -> JSONValue? {
        state.as(TilingTree.self).flatMap { JSONValue(encoding: TilingRecord($0)) }
    }

    func decode(_ json: JSONValue) -> AnyLayoutState? {
        guard let tree = json.decoded(as: TilingRecord.self)?.tree, !tree.isEmpty else { return nil }
        return AnyLayoutState(tree)
    }
}

// The commands only Auto-tile understands.
extension LayoutCommand {
    static let resizeID = "tiling.resize"
    static let joinID = "tiling.join"
    static let toggleOrientationID = "tiling.toggleOrientation"
    static let balanceID = "tiling.balance"

    /// Grows (positive) or shrinks (negative) the window by that share of its container.
    static func resize(_ delta: Double) -> LayoutCommand { LayoutCommand(resizeID, encoding: delta) }
    /// Puts the window and its neighbour in that direction into a new container.
    static func join(_ direction: TilingDirection) -> LayoutCommand { LayoutCommand(joinID, encoding: direction) }
    static let toggleOrientation = LayoutCommand(toggleOrientationID)
    static let balance = LayoutCommand(balanceID)
}

extension EngineCommand {
    static func resize(_ delta: Double) -> EngineCommand { .layout(.resize(delta)) }
    static func join(_ direction: TilingDirection) -> EngineCommand { .layout(.join(direction)) }
    static let toggleOrientation = EngineCommand.layout(.toggleOrientation)
    static let balance = EngineCommand.layout(.balance)
}
