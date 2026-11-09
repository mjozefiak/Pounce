import CoreGraphics
import Foundation
import LintelKit

// Windows: what the engine knows about each window and how events about it change that.

extension ReducerContext {
    mutating func snapshot(
        windows: [WindowInfo], displays: [DisplayInfo], focused: WindowID?, processStarts: [Int32: Double],
        now: Double
    ) {
        state.displays = displays
        state.model.setDisplays(DisplayKeys.orderedKeys(for: displays))
        state.focused = focused
        let live = windows.filter { EngineReducer.isManaged($0, config: state.config) }
        let liveIDs = Set(live.map(\.id))
        for id in Array(state.windows.keys) where !liveIDs.contains(id) { removeWindow(id) }
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
        arrangeRequested = true
    }

    /// Starts tracking a window and gives it a workspace. A window without a known process start is tracked but
    /// never parked.
    private mutating func track(_ info: WindowInfo, processStart: Double?) {
        let previous = state.windows[info.id]
        state.windows[info.id] = TrackedWindow(
            id: info.id, bundleID: info.bundleID, title: info.title, frame: info.frame,
            processStart: processStart ?? previous?.processStart)
        let display = FrameMath.display(for: info.frame, in: state.displays).map { state.displayKey(of: $0) }
        state.model.add(info.id, onDisplay: display)
    }

    mutating func windowAppeared(_ info: WindowInfo, processStart: Double?, now: Double) {
        guard EngineReducer.isManaged(info, config: state.config) else {
            // A window that stopped being managed (minimised, fullscreen, now floating) is let go.
            if state.windows[info.id] != nil { releaseUnmanaged(info.id, now: now) }
            return
        }
        if state.windows[info.id] == nil {
            track(info, processStart: processStart)
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
        if let expected = state.expected[id], expected.expires >= now,
            FrameMath.approximatelyEqual(frame, expected.frame, tolerance: state.config.echoTolerance)
        {
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
        guard !state.isFrozen, !state.floating.contains(id), !state.unmanaged.contains(id),
            let workspace = state.model.workspace(of: id), state.model.isVisible(workspace),
            let (strategy, input) = layoutInput(for: workspace), !strategy.snapTargets(input).isEmpty
        else { return }
        trailing.append(.userMovedWindow(id, frame: frame))
    }

    mutating func windowFocused(_ id: WindowID?, now: Double) {
        if let previous = state.focused, previous != id, state.windows[previous] != nil {
            state.previousFocus = previous
        }
        state.focused = id
        guard let id, state.windows[id] != nil else { return }
        state.unmanaged.remove(id)
        state.rehides[id] = nil
        if state.config.followFocus, !state.isFrozen { followFocus(of: id, now: now) }
    }
}
