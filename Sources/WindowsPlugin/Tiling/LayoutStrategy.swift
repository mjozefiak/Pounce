import CoreGraphics
import Foundation
import LintelKit

/// The geometry settings every layout strategy receives (the resolved values of one workspace).
struct LayoutGeometry: Equatable, Sendable {
    var gaps: TilingGaps
}

/// One way of arranging the windows of a workspace (spec: Architecture, "Strategy pattern for layouts"). A
/// strategy is a pure value: it owns the type of its state, how a window enters and leaves it and the frames it
/// produces. The engine stores each strategy's state under `kind` in `state.json`, so a later strategy (zones,
/// canvas, accordion) is additive and the engine does not change.
protocol LayoutStrategy: Sendable {
    associatedtype State: Equatable & Sendable

    /// The key of the state in `state.json` and the value of the layout-kind setting.
    static var kind: String { get }

    var emptyState: State { get }
    func windows(in state: State) -> [WindowID]
    func inserting(_ window: WindowID, after anchor: WindowID?, into state: State) -> State
    func removing(_ window: WindowID, from state: State) -> State
    func frames(state: State, area: CGRect, geometry: LayoutGeometry) -> [WindowID: CGRect]
}

/// Auto-tile: an i3/AeroSpace-style tree of split containers.
struct TilingStrategy: LayoutStrategy {
    static let kind = "tiling"

    var orientation: TilingOrientation = .horizontal

    var emptyState: TilingTree { TilingTree(orientation: orientation) }

    func windows(in state: TilingTree) -> [WindowID] { state.windows }

    func inserting(_ window: WindowID, after anchor: WindowID?, into state: TilingTree) -> TilingTree {
        var next = state
        next.insert(window, after: anchor)
        return next
    }

    func removing(_ window: WindowID, from state: TilingTree) -> TilingTree {
        var next = state
        next.remove(window)
        return next
    }

    func frames(state: TilingTree, area: CGRect, geometry: LayoutGeometry) -> [WindowID: CGRect] {
        TilingLayout.frames(state, area: area, gaps: geometry.gaps)
    }
}
