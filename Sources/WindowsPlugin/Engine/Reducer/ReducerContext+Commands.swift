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
            if let workspace = state.model.workspace(of: id) { switchTo(workspace, now: now, handsOffFocus: false) }
            setFocus(id, now: now)
        case .bringWindowHere(let id):
            guard state.windows[id] != nil, let current = state.model.current else { return }
            state.isFrozen = false
            if state.model.move(id, to: current) { reconcileParking(now: now) }
            setFocus(id, now: now)
        case .reload:
            reload(now: now)
        case .toggleFloating:
            guard !state.isFrozen else { return }
            // Only a window the user can see is changed: the focus may still name one that a switch just parked.
            guard let id = state.focused, isShown(id) else {
                trailing.append(.notice(.noFocusedWindow))
                return
            }
            if state.floating.remove(id) == nil { state.floating.insert(id) }
        case .layout(let layoutCommand, let id):
            if command.needsFocusedWindow, !state.isFrozen, state.focused.map({ state.windows[$0] == nil }) ?? true {
                trailing.append(.notice(.noFocusedWindow))
            }
            run(layoutCommand, on: id, now: now)
        }
    }

    private mutating func moveFocusedWindow(to workspace: WorkspaceID, now: Double) {
        guard !state.isFrozen else { return }
        // Only a window the user can see is moved: the focus may still name one that a switch just parked.
        guard let id = state.focused, state.windows[id] != nil, let old = state.model.workspace(of: id),
            state.model.isVisible(old)
        else {
            trailing.append(.notice(.noFocusedWindow))
            return
        }
        guard old != workspace else { return }
        if !state.model.isVisible(workspace), !state.canJournal {
            trailing.append(.banner(.cannotJournal))
            return
        }
        guard state.model.move(id, to: workspace) else { return }
        reconcileParking(now: now)
        // The focus goes to the window used last on the workspace the window came from; with none left it is not
        // handed to a parked window, so the next move cannot take one.
        if let next = mostRecentWindow(in: old, excluding: id) {
            setFocus(next, now: now)
        } else if state.model.workspace(of: id).map(state.model.isVisible) != true {
            state.focused = nil
            state.pendingFocus = nil
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
