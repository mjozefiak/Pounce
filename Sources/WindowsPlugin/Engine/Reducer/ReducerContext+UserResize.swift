import CoreGraphics
import Foundation
import LintelKit

// Resizing a tiled window with the mouse: the kind adopts the new size (the siblings follow), the window itself is
// left alone while the drag lasts and put on its exact tile when it settles. No kind is named here. Depends on: the
// context and the planner only.

/// A resize by hand that is going on (memory only).
struct UserResizeState: Equatable, Sendable {
    var window: WindowID
    /// When siblings were last placed because of it; adoption reflows are throttled (the watchdog counts frame changes).
    var lastReflow: Double
    /// Grows with every adopted resize; the engine's settle timer is armed again when it changes.
    var revision: Int
}

extension ReducerContext {
    /// At most one reflow of the siblings per this many seconds while the user drags (10 per second): a live drag
    /// reports every 30 ms, which with several siblings would trip the watchdog.
    static var userResizeReflowInterval: Double { 0.1 }

    /// A window of a shown workspace changed size by hand: the kind of its workspace adopts it. Returns whether it did.
    /// Ignored: our own echoes (the caller has dropped them), a window with a frame change in flight (an app that
    /// answers a size with its own, see `checkSize`), stubborn, floating and unmanaged windows, a frozen engine.
    mutating func adoptUserResize(_ id: WindowID, frame: CGRect, now: Double) -> Bool {
        guard !state.isFrozen, state.windows[id] != nil, !state.floating.contains(id), !state.unmanaged.contains(id),
            !state.stubborn.contains(id), state.parked[id] == nil,
            state.expected[id]?.entries.contains(where: { $0.expires >= now }) != true,
            let workspace = state.model.workspace(of: id), let found = planner.arrangement(state, for: workspace),
            let resizing = found.strategy.resizing, found.result.frames[id] != nil
        else { return false }
        var input = found.input
        input.state = found.result.state
        input.hints = found.result.hints
        guard let edit = resizing.adopt(frame, of: id, tiles: found.result.frames, input) else { return false }
        state.layouts[workspace, default: [:]][found.strategy.kind.rawValue] = edit.state
        state.placementHints = edit.hints
        let previous = state.userResize
        var current = UserResizeState(
            window: id, lastReflow: previous?.lastReflow ?? -.infinity, revision: (previous?.revision ?? 0) &+ 1)
        if now - current.lastReflow >= Self.userResizeReflowInterval {
            current.lastReflow = now
            arrangeRequested = true
        }
        state.userResize = current
        return true
    }

    /// The drag ended (no resize came for a while): the window is arranged like the others again, so it lands on
    /// its exact tile.
    mutating func userResizeSettled(_ id: WindowID, now: Double) {
        guard state.userResize?.window == id else { return }
        state.userResize = nil
        arrangeRequested = true
    }
}
