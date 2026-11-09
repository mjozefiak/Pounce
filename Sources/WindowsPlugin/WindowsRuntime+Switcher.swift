import Foundation
import LintelKit

/// The window switcher over a running plugin.
extension WindowsRuntime: WindowSwitching {
    func snapshot() async -> SwitcherSnapshot {
        let (membership, summary) = await engine.switcherState()
        let live = trust.isTrusted ? await context.windows.windows() : []
        let windows =
            live
            .filter { membership[$0.id] != nil }
            .map {
                SwitcherWindow(id: $0.id, title: $0.title, bundleID: $0.bundleID, workspace: membership[$0.id] ?? nil)
            }
        let workspaces = WorkspaceID.all(count: settings.workspaceCount).map {
            (workspace: $0, windowCount: summary.counts[$0] ?? 0)
        }
        return SwitcherSnapshot(workspaces: workspaces, windows: windows)
    }

    func goToWorkspace(_ workspace: WorkspaceID) async { await run(.showWorkspace(workspace), purpose: .switching) }
    func goToWindow(_ id: WindowID) async { await run(.goToWindow(id), purpose: .switching) }
    func bringHere(_ id: WindowID) async { await run(.bringWindowHere(id), purpose: .moving) }
}

/// What the switcher uses while the plugin is not running: nothing.
struct InactiveSwitcher: WindowSwitching {
    func snapshot() async -> SwitcherSnapshot { SwitcherSnapshot(workspaces: [], windows: []) }
    func goToWorkspace(_ workspace: WorkspaceID) async {}
    func goToWindow(_ id: WindowID) async {}
    func bringHere(_ id: WindowID) async {}
}
