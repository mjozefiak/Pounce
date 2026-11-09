import CoreGraphics
import Foundation
import LintelKit

// Layout: asking the strategy of each shown workspace where its windows go and applying the commands that edit
// a strategy's state. No kind is named here.

extension ReducerContext {
    /// The windows a layout arranges on a workspace, in join order: tracked, not floating, not left alone.
    private func arrangeable(_ workspace: WorkspaceID) -> [WindowID] {
        state.model.windows(in: workspace).filter {
            state.windows[$0] != nil && !state.floating.contains($0) && !state.unmanaged.contains($0)
        }
    }

    /// The strategy of a shown workspace and what it needs, or `nil` when nothing is arranged now (the engine is
    /// frozen, the workspace is hidden or on no display). Pure.
    func layoutInput(for workspace: WorkspaceID) -> (any LayoutStrategy, LayoutInput)? {
        guard !state.isFrozen, state.model.isVisible(workspace) else { return nil }
        let kind = state.config.layout.resolved(for: workspace).kind
        guard let strategy = strategies[kind], let shown = state.model.displayShowing(workspace),
            let display = state.display(forKey: shown)
        else { return nil }
        let windows = arrangeable(workspace)
        var apps: [WindowID: String] = [:]
        for id in windows { apps[id] = state.windows[id]?.bundleID }
        return (
            strategy,
            LayoutInput(
                workspace: workspace, windows: windows, apps: apps, state: state.layouts[workspace]?[kind.rawValue],
                config: state.config.strategyConfigs[kind], resolved: state.config.layout.resolved(for: workspace),
                focused: state.focused, previousFocus: state.previousFocus, display: display, displayKey: shown,
                hints: state.placementHints)
        )
    }

    /// Where every window of a shown workspace goes, with the strategy's state brought up to date. Pure: the
    /// result is stored by `commit`.
    func arrangement(for workspace: WorkspaceID) -> (
        strategy: any LayoutStrategy, input: LayoutInput, result: LayoutArrangement
    )? {
        guard let (strategy, input) = layoutInput(for: workspace) else { return nil }
        return (strategy, input, strategy.arrange(input))
    }

    mutating func commit(_ result: LayoutArrangement, kind: LayoutKind, workspace: WorkspaceID) {
        if let next = result.state, state.layouts[workspace]?[kind.rawValue] != next {
            state.layouts[workspace, default: [:]][kind.rawValue] = next
        }
        if state.placementHints != result.hints { state.placementHints = result.hints }
    }

    /// Where a window goes: its slot, or centred in it when the window refused the size it was given.
    func placement(of id: WindowID) -> CGRect? {
        guard state.windows[id] != nil, let workspace = state.model.workspace(of: id),
            let tile = arrangement(for: workspace)?.result.frames[id]
        else { return nil }
        return target(for: id, tile: tile)
    }

    func target(for id: WindowID, tile: CGRect) -> CGRect {
        guard state.stubborn.contains(id), let window = state.windows[id] else { return tile }
        return FrameMath.centered(size: window.frame.size, in: tile)
    }

    /// Removes a gone window from the state of every kind of every workspace.
    mutating func forgetInLayouts(_ id: WindowID) {
        for workspace in state.layouts.keys.sorted() {
            for name in state.layouts[workspace]?.keys.sorted() ?? [] {
                guard let strategy = strategies[LayoutKind(name)],
                    let current = state.layouts[workspace]?[name]
                else { continue }
                let next = strategy.removing(id, from: current)
                if next.isEmpty {
                    state.layouts[workspace]?[name] = nil
                } else if next != current {
                    state.layouts[workspace]?[name] = next
                }
            }
            if state.layouts[workspace]?.isEmpty == true { state.layouts[workspace] = nil }
        }
    }

    /// The stored states of an earlier run, for the workspaces that exist.
    mutating func restoreLayouts(_ stored: [WorkspaceID: [String: JSONValue]]) {
        state.layouts = strategies.decode(stored).filter { state.model.workspaces.contains($0.key) }
    }

    /// Drops the states of workspaces that no longer exist.
    mutating func pruneLayouts() {
        state.layouts = state.layouts.filter { state.model.workspaces.contains($0.key) }
    }

    /// Runs a layout command on a window (the focused one by default); the strategy answers `nil` when it does not
    /// apply. The window must be managed, not floating, and arranged on a shown workspace.
    mutating func run(_ command: LayoutCommand, on window: WindowID? = nil) {
        guard !state.isFrozen, let id = window ?? state.focused, state.windows[id] != nil,
            !state.floating.contains(id), !state.unmanaged.contains(id), let workspace = state.model.workspace(of: id),
            let found = arrangement(for: workspace), found.result.frames[id] != nil
        else { return }
        // The strategy edits the state as brought up to date by the arrangement.
        var input = found.input
        input.state = found.result.state
        input.hints = found.result.hints
        guard let edit = found.strategy.perform(command, on: id, input) else { return }
        state.layouts[workspace, default: [:]][found.strategy.kind.rawValue] = edit.state
        state.placementHints = edit.hints
        if let next = edit.focus {
            state.previousFocus = id
            state.focused = next
            trailing.append(.focus(next))
        }
    }

    mutating func arrangeIfRequested(now: Double) {
        guard arrangeRequested else { return }
        arrangeRequested = false
        guard !state.isFrozen else { return }
        for workspace in state.model.workspaces where state.model.isVisible(workspace) {
            guard let found = arrangement(for: workspace) else { continue }
            commit(found.result, kind: found.strategy.kind, workspace: workspace)
            let tiles = found.result.frames
            for id in tiles.keys.sorted() {
                guard let tile = tiles[id], let window = state.windows[id], state.parked[id] == nil,
                    !state.unmanaged.contains(id), !requests.contains(where: { $0.id == id })
                else { continue }
                let tolerance = state.config.echoTolerance
                // A stubborn window gets one new try when its tile changed size (never a loop: the size is
                // remembered, and a window that refuses again becomes stubborn again).
                if state.stubborn.contains(id), let last = state.tileSizes[id],
                    abs(last.width - tile.width) > tolerance || abs(last.height - tile.height) > tolerance
                {
                    state.stubborn.remove(id)
                }
                state.tileSizes[id] = tile.size
                let frame = target(for: id, tile: tile)
                if FrameMath.approximatelyEqual(window.frame, frame, tolerance: tolerance) { continue }
                if let expected = state.expected[id], expected.expires >= now,
                    FrameMath.approximatelyEqual(expected.frame, frame, tolerance: tolerance)
                {
                    continue
                }
                request(id, frame, .place, now: now)
            }
        }
    }
}
