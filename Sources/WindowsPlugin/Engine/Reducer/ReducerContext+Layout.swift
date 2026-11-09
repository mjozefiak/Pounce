import CoreGraphics
import Foundation
import LintelKit

// Layout: storing what the planner computed and applying the commands that edit a strategy's state. Reads go
// through `LayoutPlanner`; no kind is named here. Depends on: the context and the planner only.

extension ReducerContext {
    mutating func commit(_ result: LayoutArrangement, kind: LayoutKind, workspace: WorkspaceID) {
        if let next = result.state, state.layouts[workspace]?[kind.rawValue] != next {
            state.layouts[workspace, default: [:]][kind.rawValue] = next
        }
        if state.placementHints != result.hints { state.placementHints = result.hints }
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
            let found = planner.arrangement(state, for: workspace), found.result.frames[id] != nil
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
            guard let found = planner.arrangement(state, for: workspace) else { continue }
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
                let frame = planner.target(state, for: id, tile: tile)
                if FrameMath.approximatelyEqual(window.frame, frame, tolerance: tolerance) { continue }
                if state.expected[id]?.newestMatches(frame, now: now, tolerance: tolerance) == true { continue }
                request(id, frame, .place, now: now)
            }
        }
    }
}
