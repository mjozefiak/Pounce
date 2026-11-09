import CoreGraphics
import Foundation
import LintelKit

/// The engine's one decision function. It reads no clock, no client and no disk: time arrives in the inputs and
/// everything it wants done is returned as effects (spec: Architecture).
///
/// The visible workspaces decide where every managed window should be: on screen when its workspace is shown,
/// parked when it is not. After any change `reconcileParking` compares that with what is parked now and emits
/// the difference, so a command, a display change and a re-hide all take the same path. How a shown workspace is
/// arranged is the business of its `LayoutStrategy`; the reducer asks the registry and knows no kind.
///
/// The work is split by concern into extensions of `ReducerContext` (the working state of one reduction):
/// `Reducer/ReducerContext+Parking`, `+Windows`, `+Layout`, `+Commands` and `+Results`.
enum EngineReducer {
    static func reduce(
        _ state: EngineState, _ input: EngineInput, strategies: LayoutRegistry = .standard
    ) -> (EngineState, [EngineEffect]) {
        var context = ReducerContext(state: state, strategies: strategies)
        let oldOrder = state.model.order
        let oldLayouts = state.layouts
        let oldSummary = summary(of: state)

        switch input {
        case .snapshot(let windows, let displays, let focused, let processStarts, let now):
            context.snapshot(
                windows: windows, displays: displays, focused: focused, processStarts: processStarts, now: now)
        case .windowAppeared(let info, let processStart, let now):
            context.windowAppeared(info, processStart: processStart, now: now)
        case .windowGone(let id, _):
            context.removeWindow(id)
        case .windowMoved(let id, let frame, let now):
            context.windowMoved(id, frame: frame, now: now)
        case .windowFocused(let id, let now):
            context.windowFocused(id, now: now)
        case .displaysChanged(let displays, let now):
            context.displaysChanged(displays, now: now)
        case .command(let command, let now):
            context.perform(command, now: now)
        case .applied(let results, let now):
            context.applied(results, now: now)
        case .frameStarted(let request, let now):
            context.frameStarted(request, now: now)
        case .watchdogTripped(let now):
            context.watchdogTripped(now: now)
        case .configChanged(let config):
            context.state.config = config
        case .journalAvailability(let available):
            context.state.canJournal = available
        case .place(let id, let rect, let now):
            context.place(id, rect, now: now)
        case .restoreLayouts(let stored):
            context.restoreLayouts(stored)
        }

        context.arrangeIfRequested(now: input.moment ?? 0)
        context.flush()
        if context.state.model.order != oldOrder {
            context.effects.append(.saveOrder(context.state.model.order))
        }
        if context.state.layouts != oldLayouts {
            context.effects.append(.saveLayouts(context.state.layouts))
        }
        let newSummary = summary(of: context.state)
        if newSummary != oldSummary {
            context.effects.append(.summaryChanged(newSummary))
        }
        return (context.state, context.effects)
    }

    static func summary(of state: EngineState) -> WorkspaceSummary {
        WorkspaceSummary(
            current: state.model.current,
            visible: state.model.visible,
            counts: Dictionary(
                uniqueKeysWithValues: state.model.workspaces.map { ($0, state.model.windowCount(in: $0)) }),
            focusedDisplay: state.model.focusedDisplay
        )
    }

    /// Whether the engine arranges a window at all: a standard window of a regular app that is neither minimised
    /// nor fullscreen and not on the floating list.
    static func isManaged(_ info: WindowInfo, config: EngineConfig) -> Bool {
        guard info.isStandard, !info.isMinimized, !info.isFullscreen else { return false }
        if let bundleID = info.bundleID, config.floatingBundleIDs.contains(bundleID) { return false }
        return true
    }

    /// The slots the snap overlay offers while a window is dragged: the display that shows the window's
    /// workspace with the layout that workspace uses there. Nothing unless the workspace is shown and the engine
    /// is not frozen, so the overlay never appears where a snap could not happen.
    static func snapTargets(
        _ state: EngineState, for window: WindowID, strategies: LayoutRegistry = .standard
    ) -> [DragDisplay] {
        let context = ReducerContext(state: state, strategies: strategies)
        guard state.windows[window] != nil, let workspace = state.model.workspace(of: window),
            let (strategy, input) = context.layoutInput(for: workspace)
        else { return [] }
        return strategy.snapTargets(input)
    }
}
