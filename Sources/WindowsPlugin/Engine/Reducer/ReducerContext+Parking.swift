import CoreGraphics
import Foundation
import LintelKit

// Parking: the visible workspaces decide which windows are on screen; everything else is parked in a corner.

extension ReducerContext {
    mutating func park(_ id: WindowID, now: Double) {
        guard var window = state.windows[id], let start = window.processStart, state.parked[id] == nil,
            !state.displays.isEmpty
        else { return }
        let parked = FrameMath.parkedFrame(
            for: window.frame, displays: state.displays, sliver: state.config.parkSliver)
        state.parked[id] = ParkRecord(home: window.frame, parkedFrame: parked, processStart: start)
        journal.append(HiddenEntry(windowID: id, processStart: start, homeFrame: FrameRecord(window.frame)))
        window.frame = parked
        state.windows[id] = window
        request(id, parked, .park, now: now)
    }

    /// Puts a parked window back: onto its tile when its workspace is arranged, else to where it was.
    mutating func restore(_ id: WindowID, now: Double, arranged: Bool = true) {
        var cache = PlacementCache()
        restore(id, now: now, arranged: arranged, cache: &cache)
    }

    /// `restore` for many windows of one reduction: the planner is asked once per workspace, not once per window
    /// (the requests it makes change nothing the planner reads).
    mutating func restore(_ id: WindowID, now: Double, arranged: Bool, cache: inout PlacementCache) {
        guard let record = state.parked[id] else { return }
        let frame =
            (arranged ? cache.tile(of: id, state, planner) : nil)
            ?? FrameMath.restoredFrame(home: record.home, displays: state.displays)
        request(id, frame, .restore, now: now)
    }

    /// Parks the windows of hidden workspaces and restores the windows of shown ones.
    mutating func reconcileParking(now: Double) {
        guard !state.isFrozen else { return }
        var cache = PlacementCache()
        for (id, _) in state.windows.sorted(by: { $0.key < $1.key }) where !state.unmanaged.contains(id) {
            guard let workspace = state.model.workspace(of: id) else { continue }
            if state.model.isVisible(workspace) {
                if state.parked[id] != nil { restore(id, now: now, arranged: true, cache: &cache) }
            } else if state.parked[id] == nil {
                guard state.canJournal else {
                    trailing.append(.banner(.cannotJournal))
                    continue
                }
                park(id, now: now)
            }
        }
    }

    mutating func displaysChanged(_ displays: [DisplayInfo], now: Double) {
        state.displays = displays
        state.model.setDisplays(DisplayKeys.orderedKeys(for: displays))
        arrangeRequested = true
        reconcileParking(now: now)
        guard !state.isFrozen else { return }
        // Parked windows are re-parked in the new corner of their display.
        for (id, record) in state.parked.sorted(by: { $0.key < $1.key }) {
            // A window whose workspace is shown again is being restored, not re-parked.
            if let workspace = state.model.workspace(of: id), state.model.isVisible(workspace) { continue }
            guard !displays.isEmpty else { continue }
            let corner = FrameMath.parkedFrame(for: record.home, displays: displays, sliver: state.config.parkSliver)
            if !FrameMath.originsApproximatelyEqual(corner, record.parkedFrame, tolerance: 0.5) {
                state.parked[id]?.parkedFrame = corner
                state.windows[id]?.frame = corner
                request(id, corner, .park, now: now)
            }
        }
    }

    /// Switches to the workspace of a window that got focus while its workspace was hidden.
    mutating func followFocus(of id: WindowID, now: Double) {
        guard let workspace = state.model.workspace(of: id), !state.model.isVisible(workspace) else {
            // Shown, but a parked window may need to come back (it was moved while its workspace was shown).
            if state.parked[id] != nil, state.model.workspace(of: id).map(state.model.isVisible) == true {
                restore(id, now: now)
            }
            return
        }
        switchTo(workspace, now: now)
    }

    mutating func switchTo(_ workspace: WorkspaceID, now: Double) {
        let hidden = hiddenWindowsIfShown(workspace)
        if !state.canJournal, hidden {
            trailing.append(.banner(.cannotJournal))
            return
        }
        let before = state.model.current
        state.model.show(workspace)
        arrangeRequested = true
        reconcileParking(now: now)
        if let current = state.model.current, current != before {
            trailing.append(.hud(workspace: current, windowCount: state.model.windowCount(in: current)))
        }
    }

    /// Whether showing `workspace` would park a window.
    private func hiddenWindowsIfShown(_ workspace: WorkspaceID) -> Bool {
        var probe = state.model
        probe.show(workspace)
        return probe.hiddenWindows.contains { id in
            state.windows[id] != nil && state.parked[id] == nil && !state.unmanaged.contains(id)
        }
    }

    /// Puts every parked window back. The engine then stays still (`isFrozen`) until the next workspace
    /// command, so windows of hidden workspaces that are on screen now are not hidden again behind the user's
    /// back.
    mutating func restoreAll(now: Double) {
        state.isFrozen = true
        var cache = PlacementCache()
        for id in state.parked.keys.sorted() { restore(id, now: now, arranged: true, cache: &cache) }
    }

    /// *Reset state*: everything that is only remembered (membership, layout states, placement hints) starts over;
    /// every tracked window joins the workspace shown on its display. The journal and `state.parked` stay, so a
    /// window that could not be put back can still be. Both stored values are written, changed or not, because the
    /// caller has just cleared them on disk.
    mutating func resetState(now: Double) {
        restoreAll(now: now)
        let model = state.model
        state.model = VirtualWorkspaceModel(workspaceCount: model.workspaceCount, displays: model.displays)
        state.layouts = [:]
        state.placementHints = [:]
        state.previousFocus = nil
        for id in state.windows.keys.sorted() {
            guard let window = state.windows[id] else { continue }
            // A window that is still parked sits in the corner of all displays: its home says where it belongs.
            let frame = state.parked[id]?.home ?? window.frame
            let display = FrameMath.display(for: frame, in: state.displays).map { state.displayKey(of: $0) }
            state.model.add(id, onDisplay: display)
        }
        effects.append(.saveOrder(state.model.order))
        effects.append(.saveLayouts(state.layouts))
        arrangeRequested = true
    }

    mutating func watchdogTripped(now: Double) {
        state.diagnostics.watchdogTrips += 1
        trailing.append(.banner(.watchdogTripped))
        restoreAll(now: now)
    }
}
