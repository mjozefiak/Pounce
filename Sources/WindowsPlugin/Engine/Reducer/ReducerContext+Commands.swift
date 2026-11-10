import CoreGraphics
import Foundation
import LintelKit

// Commands: what each `EngineCommand` does. Workspace commands act here; layout commands go to the strategy of
// the focused window's workspace.

extension ReducerContext {
    mutating func perform(_ command: EngineCommand, now: Double) {
        arrangeRequested = true
        switch command {
        case .restoreAll:
            restoreAll(now: now)
        case .resetState:
            resetState(now: now)
        case .showWorkspace(let workspace):
            state.isFrozen = false
            switchTo(workspace, now: now)
        case .nextWorkspace, .previousWorkspace:
            guard let current = state.model.current else { return }
            let count = state.model.workspaceCount
            let delta = command == .nextWorkspace ? 1 : count - 1
            guard let target = WorkspaceID((current.rawValue - 1 + delta) % count + 1) else { return }
            state.isFrozen = false
            switchTo(target, now: now)
        case .backAndForth:
            guard let target = state.model.previous else { return }
            state.isFrozen = false
            switchTo(target, now: now)
        case .moveFocusedWindow(let workspace):
            moveFocusedWindow(to: workspace, now: now)
        case .setWorkspaceCount(let count):
            state.model.setWorkspaceCount(count)
            pruneLayouts()
            reconcileParking(now: now)
        case .goToWindow(let id):
            guard state.windows[id] != nil else { return }
            state.isFrozen = false
            if let workspace = state.model.workspace(of: id) { switchTo(workspace, now: now) }
            trailing.append(.focus(id))
        case .bringWindowHere(let id):
            guard state.windows[id] != nil, let current = state.model.current else { return }
            state.isFrozen = false
            if state.model.move(id, to: current) { reconcileParking(now: now) }
            trailing.append(.focus(id))
        case .reload:
            reload(now: now)
        case .toggleFloating:
            guard !state.isFrozen, let id = state.focused, state.windows[id] != nil else { return }
            if state.floating.remove(id) == nil { state.floating.insert(id) }
        case .layout(let layoutCommand, let id): run(layoutCommand, on: id)
        }
    }

    private mutating func moveFocusedWindow(to workspace: WorkspaceID, now: Double) {
        guard !state.isFrozen, let id = state.focused, state.windows[id] != nil,
            let old = state.model.workspace(of: id), old != workspace
        else { return }
        if !state.model.isVisible(workspace), !state.canJournal {
            trailing.append(.banner(.cannotJournal))
            return
        }
        guard state.model.move(id, to: workspace) else { return }
        reconcileParking(now: now)
        // The focus goes to what is left on the workspace the window came from.
        if let next = state.model.windows(in: old).last(where: { $0 != id }), state.model.isVisible(old) {
            trailing.append(.focus(next))
        }
    }

    /// After a setting changed. Windows of apps that just joined the floating list are let go.
    private mutating func reload(now: Double) {
        let config = state.config
        for (id, window) in state.windows.sorted(by: { $0.key < $1.key }) {
            if let bundleID = window.bundleID, config.floatingBundleIDs.contains(bundleID) {
                releaseUnmanaged(id, now: now)
            }
        }
        pruneLayouts()
        arrangeRequested = true
    }

    /// Asks a window to be placed at a frame, as a layout does.
    mutating func place(_ id: WindowID, _ rect: CGRect, now: Double) {
        guard let window = state.windows[id], !state.isFrozen, state.parked[id] == nil else { return }
        let target = state.stubborn.contains(id) ? FrameMath.centered(size: window.frame.size, in: rect) : rect
        request(id, target, .place, now: now)
    }
}
