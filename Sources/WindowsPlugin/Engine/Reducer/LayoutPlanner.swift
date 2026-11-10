import CoreGraphics
import Foundation
import LintelKit

/// Reads the engine state and asks the strategy of a workspace's kind where its windows go. Pure and read-only: it
/// never changes the state (the reducer stores what it returns), so the reducer's other parts can query it from
/// anywhere without a cycle. It names no kind.
struct LayoutPlanner: Sendable {
    let strategies: LayoutRegistry

    /// The windows a layout arranges on a workspace, in join order: tracked, not floating, not left alone.
    private func arrangeable(_ state: EngineState, _ workspace: WorkspaceID) -> [WindowID] {
        state.model.windows(in: workspace).filter {
            state.windows[$0] != nil && !state.floating.contains($0) && !state.unmanaged.contains($0)
        }
    }

    /// The strategy of a shown workspace and what it needs, or `nil` when nothing is arranged now (the engine is
    /// frozen, the workspace is hidden or on no display).
    func input(_ state: EngineState, for workspace: WorkspaceID) -> (any LayoutStrategy, LayoutInput)? {
        guard !state.isFrozen, state.model.isVisible(workspace) else { return nil }
        let resolved = state.config.layout.resolved(for: workspace)
        let kind = resolved.kind
        guard let strategy = strategies[kind], let shown = state.model.displayShowing(workspace),
            let display = state.display(forKey: shown)
        else { return nil }
        let windows = arrangeable(state, workspace)
        var apps: [WindowID: String] = [:]
        for id in windows { apps[id] = state.windows[id]?.bundleID }
        return (
            strategy,
            LayoutInput(
                workspace: workspace, windows: windows, apps: apps, state: state.layouts[workspace]?[kind.rawValue],
                config: state.config.strategyConfigs[kind], resolved: resolved, focused: state.focused,
                previousFocus: state.previousFocus, display: display, displayKey: shown, hints: state.placementHints)
        )
    }

    /// Where every window of a shown workspace goes, with the strategy's state brought up to date.
    func arrangement(_ state: EngineState, for workspace: WorkspaceID) -> (
        strategy: any LayoutStrategy, input: LayoutInput, result: LayoutArrangement
    )? {
        guard let (strategy, input) = input(state, for: workspace) else { return nil }
        return (strategy, input, strategy.arrange(input))
    }

    /// Where a window goes: its slot, or centred in it when the window refused the size it was given.
    func placement(_ state: EngineState, of id: WindowID, in frames: [WindowID: CGRect]) -> CGRect? {
        frames[id].map { target(state, for: id, tile: $0) }
    }

    func target(_ state: EngineState, for id: WindowID, tile: CGRect) -> CGRect {
        guard state.stubborn.contains(id), let window = state.windows[id] else { return tile }
        return FrameMath.centered(size: window.frame.size, in: tile)
    }

    /// Whether moving a window of this workspace by hand may start a snap drag. Cheap: no layout input is built.
    func offersSnapTargets(_ state: EngineState, for workspace: WorkspaceID) -> Bool {
        strategies[state.config.layout.resolved(for: workspace).kind]?.snapping != nil
    }
}

/// Where the windows of each shown workspace go, computed once per reduction step that needs several of them.
struct PlacementCache {
    private var frames: [WorkspaceID: [WindowID: CGRect]] = [:]

    /// The tile of `id`, asking the planner for its workspace only the first time.
    mutating func tile(of id: WindowID, _ state: EngineState, _ planner: LayoutPlanner) -> CGRect? {
        guard state.windows[id] != nil, let workspace = state.model.workspace(of: id) else { return nil }
        if frames[workspace] == nil {
            frames[workspace] = planner.arrangement(state, for: workspace)?.result.frames ?? [:]
        }
        return frames[workspace]?[id].map { planner.target(state, for: id, tile: $0) }
    }
}
