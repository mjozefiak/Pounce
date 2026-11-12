import CoreGraphics
import Foundation
import LintelKit

// Windows: what the engine knows about each window and how events about it change that.

extension ReducerContext {
    mutating func snapshot(
        windows: [WindowInfo], displays: [DisplayInfo], focused: WindowID?, processStarts: [Int32: Double],
        unreachable: Set<Int32> = [], unreadable: Set<WindowID> = [], now: Double
    ) {
        state.displays = displays
        state.model.setDisplays(DisplayKeys.orderedKeys(for: displays))
        state.focused = focused
        if let focused { touchRecency(focused) }
        let live = windows.filter { EngineReducer.isManaged($0, config: state.config) }
        let liveIDs = Set(live.map(\.id))
        // What could not be read marks its processes unresponsive; what could be read clears them.
        let readPIDs = Set(windows.map(\.id.pid))
        state.unresponsive.formUnion(unreachable)
        state.unresponsive.formUnion(unreadable.map(\.pid))
        state.unresponsive.subtract(readPIDs.subtracting(unreachable).subtracting(unreadable.map(\.pid)))
        // A window that is missing is gone, unless its process did not answer: then it is only unknown and stays
        // (parked or not) until a later look, so a hung app never loses its windows.
        for id in Array(state.windows.keys)
        where !liveIDs.contains(id) && !unreachable.contains(id.pid) && !unreadable.contains(id) {
            removeWindow(id)
        }
        for info in live {
            if state.windows[info.id] == nil {
                track(info, processStart: processStarts[info.id.pid])
            } else if state.parked[info.id] == nil {
                if let start = processStarts[info.id.pid] { state.windows[info.id]?.processStart = start }
                state.windows[info.id]?.title = info.title
                state.windows[info.id]?.frame = info.frame
            } else {
                // A parked window that is somewhere else now: it came back on its own.
                windowMoved(info.id, frame: info.frame, now: now)
            }
        }
        reconcileParking(now: now)
        // An app that did not answer and of which the engine tracks nothing: its windows are not known yet.
        let held = Set(state.windows.keys.map(\.pid))
        state.unknownApps = unreachable.subtracting(held)
        arrangeRequested = true
    }

    /// Starts tracking a window and gives it a workspace. A window without a known process start is tracked but
    /// never parked.
    private mutating func track(_ info: WindowInfo, processStart: Double?, appliesRules: Bool = false) {
        let previous = state.windows[info.id]
        state.windows[info.id] = TrackedWindow(
            id: info.id, bundleID: info.bundleID, title: info.title, frame: info.frame,
            processStart: processStart ?? previous?.processStart)
        let display = FrameMath.display(for: info.frame, in: state.displays).map { state.displayKey(of: $0) }
        // A rule gives a window that is created now (never one that was there at the start) its workspace, without
        // switching to it; a workspace that is hidden parks it with the next reconcile.
        let ruled = appliesRules ? info.bundleID.flatMap { state.config.appWorkspaces[$0] } : nil
        state.model.add(info.id, to: ruled, onDisplay: display)
    }

    mutating func windowAppeared(_ info: WindowInfo, processStart: Double?, now: Double) {
        guard EngineReducer.isManaged(info, config: state.config) else {
            // A window that stopped being managed (minimised, fullscreen, now floating) is let go.
            if state.windows[info.id] != nil { releaseUnmanaged(info.id, now: now) }
            return
        }
        if state.windows[info.id] == nil {
            track(info, processStart: processStart, appliesRules: true)
            arrangeRequested = true
        } else {
            if let processStart { state.windows[info.id]?.processStart = processStart }
            state.windows[info.id]?.title = info.title
            if state.parked[info.id] == nil { state.windows[info.id]?.frame = info.frame }
        }
        reconcileParking(now: now)
    }

    /// A window the engine no longer manages is put back (when parked) and forgotten.
    mutating func releaseUnmanaged(_ id: WindowID, now: Double) {
        // A parked window keeps its parked record until the restore result arrives and clears its journal entry,
        // so the record is the only thing kept.
        if state.parked[id] != nil { restore(id, now: now, arranged: false) }
        state.model.remove(id)
        state.windows[id] = nil
        state.floating.remove(id)
        if state.previousFocus == id { state.previousFocus = nil }
        forgetRecency(id)
        arrangeRequested = true
        state.unmanaged.remove(id)
        state.rehides[id] = nil
        state.stubborn.remove(id)
        state.tileSizes[id] = nil
    }

    mutating func removeWindow(_ id: WindowID) {
        let wasParked = state.parked[id] != nil
        state.model.remove(id)
        state.windows[id] = nil
        state.floating.remove(id)
        if state.previousFocus == id { state.previousFocus = nil }
        forgetRecency(id)
        arrangeRequested = true
        state.parked[id] = nil
        state.expected[id] = nil
        state.stubborn.remove(id)
        state.tileSizes[id] = nil
        state.rehides[id] = nil
        state.unmanaged.remove(id)
        state.latest[id] = nil
        forgetInLayouts(id)
        if state.focused == id { state.focused = nil }
        if wasParked { effects.append(.journalRemove([id])) }
    }

    mutating func windowMoved(_ id: WindowID, frame: CGRect, now: Double) {
        guard state.windows[id] != nil else { return }
        if state.expected[id]?.matches(frame, now: now, tolerance: state.config.echoTolerance) == true {
            state.diagnostics.echoesDropped += 1
            return
        }
        guard let record = state.parked[id] else {
            state.windows[id]?.frame = frame
            noteUserMove(id, frame: frame)
            return
        }
        if FrameMath.originsApproximatelyEqual(frame, record.parkedFrame, tolerance: state.config.echoTolerance) {
            return
        }
        guard !state.isFrozen else {
            state.windows[id]?.frame = frame
            return
        }
        // A hidden window moved on screen by itself (an app restoring its position).
        if state.focused == id, state.config.followFocus {
            followFocus(of: id, now: now)
            return
        }
        let count = (state.rehides[id] ?? 0) + 1
        state.rehides[id] = count
        state.diagnostics.rehides += 1
        if count > state.config.rehideCap {
            // Stop the fight: leave it where it is until the user focuses it.
            state.unmanaged.insert(id)
            state.parked[id] = nil
            state.windows[id]?.frame = frame
            effects.append(.journalRemove([id]))
            return
        }
        guard !state.displays.isEmpty else { return }
        let parked = FrameMath.parkedFrame(for: frame, displays: state.displays, sliver: state.config.parkSliver)
        state.parked[id]?.parkedFrame = parked
        state.windows[id]?.frame = parked
        request(id, parked, .park, now: now)
    }

    /// A managed window of a shown workspace moved by itself: a strategy with snap targets (a drag detector) may
    /// want to look at the pointer.
    private mutating func noteUserMove(_ id: WindowID, frame: CGRect) {
        guard planner.canStartSnapDrag(state, id) else { return }
        trailing.append(.userMovedWindow(id, frame: frame))
    }

    mutating func windowFocused(_ id: WindowID?, now: Double) {
        if let previous = state.focused, previous != id, state.windows[previous] != nil {
            state.previousFocus = previous
        }
        state.focused = id
        // The system caught up with the focus the engine asked for (or the user chose another window: the
        // request is over either way once its target is confirmed; a different window waits for the timeout).
        if let pending = state.pendingFocus, pending.id == id { state.pendingFocus = nil }
        guard let id, state.windows[id] != nil else { return }
        touchRecency(id)
        if let workspace = state.model.workspace(of: id), state.model.isVisible(workspace),
            planner.arrangesOnFocusChange(state, for: workspace)
        {
            arrangeRequested = true
        }
        state.unmanaged.remove(id)
        state.rehides[id] = nil
        if state.config.followFocus, !state.isFrozen { followFocus(of: id, now: now) }
    }

    /// The system's focus, read just before a command that acts on the focused window. It sets `focused` and
    /// nothing else (no workspace switch). While the engine waits for the system to follow a focus change it asked
    /// for, an observation that shows a window the user cannot see (hidden, parked, unknown) is the system lagging
    /// behind, so the requested window stays (`PendingFocus`); any other observation wins over `focused`.
    mutating func focusObserved(_ observed: WindowID?, now: Double) {
        var effective = observed
        // A request older than `PendingFocus.lifetime` (engine time, read from the inputs) is over: the system had
        // time to follow it, or never will.
        if let pending = state.pendingFocus, pending.expires <= now { state.pendingFocus = nil }
        if let pending = state.pendingFocus {
            if pending.id == observed {
                state.pendingFocus = nil
            } else if !isShown(observed) {
                effective = pending.id
            }
        }
        let known = effective.flatMap { state.windows[$0] != nil ? $0 : nil }
        let believed = state.focused.flatMap { state.windows[$0] != nil ? $0 : nil }
        if known != believed {
            state.diagnostics.focusMismatches += 1
            if let believed { state.previousFocus = believed }
        }
        state.focused = known
        if let known { touchRecency(known) }
    }
}
