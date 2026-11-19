import CoreGraphics
import Foundation
import LintelKit

// Resizing a tiled window with the mouse: the kind adopts the new size (the siblings follow), the window itself is
// left alone while the drag lasts (the mouse button is held) and put on its exact tile when it settles. No kind is
// named here. Depends on: the context and the planner only.

/// A resize by hand that is going on (memory only).
struct UserResizeState: Equatable, Sendable {
    var window: WindowID
    /// When siblings were last placed because of it; adoption reflows are throttled (the watchdog counts frame changes).
    var lastReflow: Double
    /// Grows with every adopted resize; the engine's settle timer is armed again when it changes.
    var revision: Int
}

extension ReducerContext {
    /// How long after a display change a size change is not taken for a resize by hand (seconds, engine clock).
    static var displaySettleDuration: Double { 3 }

    /// The frame changes per second a drag may cause: half the watchdog's limit, so the rest of the engine keeps room.
    static var userResizeFrameBudget: Double { Double(Watchdog.defaultLimit) / 2 }

    /// The shortest time between two reflows of the siblings while the user drags: at most 10 per second, fewer when a
    /// reflow moves many windows, so the frame changes stay within `userResizeFrameBudget`. A live drag reports every
    /// 30 ms, and the watchdog counts every frame change (8 windows reflowed 10 times a second would trip it).
    static func userResizeReflowInterval(moving windows: Int) -> Double {
        max(0.1, Double(max(0, windows)) / userResizeFrameBudget)
    }

    /// A window of a shown workspace changed size by hand: the kind of its workspace adopts it. Returns whether it did.
    /// Ignored: our own echoes (the caller has dropped them), a window with a frame change in flight (an app that
    /// answers a size with its own, see `checkSize`), stubborn, floating and unmanaged windows, a frozen engine, and
    /// any size change for `displaySettleDuration` after the displays changed.
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
        // After a wake or a display change the system resizes windows by itself (a fallback display of another size
        // can appear for a moment); adopting that would rewrite the stored weights. The next arrange undoes it.
        // Checked last, so the count holds only size changes that would otherwise have been adopted.
        if now < state.displaySettleUntil {
            state.diagnostics.resizesIgnoredDuringDisplaySettle += 1
            return false
        }
        state.layouts[workspace, default: [:]][found.strategy.kind.rawValue] = edit.state
        state.placementHints = edit.hints
        let previous = state.userResize
        var current = UserResizeState(
            window: id, lastReflow: previous?.lastReflow ?? -.infinity, revision: (previous?.revision ?? 0) &+ 1)
        // Every other window of the workspace may move in one reflow (the dragged one is left alone).
        let interval = Self.userResizeReflowInterval(moving: found.result.frames.count - 1)
        if now - current.lastReflow >= interval {
            current.lastReflow = now
            arrangeRequested = true
        }
        state.userResize = current
        return true
    }

    /// No resize of the window came for a while. Released (the mouse button is up): the drag is over, and the window is
    /// arranged like the others again, so it lands on its exact tile. Still held (the user only paused): the siblings
    /// catch up with the last adopted size, which a throttled event may have left out, and the window stays alone.
    mutating func userResizeSettled(_ id: WindowID, released: Bool, now: Double) {
        guard state.userResize?.window == id else { return }
        if released {
            state.userResize = nil
        } else {
            state.userResize?.lastReflow = now
        }
        arrangeRequested = true
    }
}
