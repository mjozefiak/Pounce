import Foundation
import LintelKit

/// The commands that change which layout a workspace uses: *Toggle layout*, the nine layout slots and *Next zone
/// layout*. They write settings or assignments and then ask the runtime to apply them; every one is behind the
/// Accessibility gate, because the windows are placed again.
@MainActor
final class LayoutCommands {
    private let settings: WindowsSettings
    private let assignments: AssignmentStore
    private let layouts: LayoutRepository
    private let engine: WindowEngine
    private let trust: AccessibilityTrust
    private let hud: any WindowsHUDPresenting
    private let context: PluginContext
    private let currentWorkspace: @MainActor () -> WorkspaceID?
    private let apply: @MainActor () async -> Void

    init(
        context: PluginContext, settings: WindowsSettings, assignments: AssignmentStore, layouts: LayoutRepository,
        engine: WindowEngine, trust: AccessibilityTrust, hud: any WindowsHUDPresenting,
        currentWorkspace: @escaping @MainActor () -> WorkspaceID?, apply: @escaping @MainActor () async -> Void
    ) {
        self.context = context
        self.settings = settings
        self.assignments = assignments
        self.layouts = layouts
        self.engine = engine
        self.trust = trust
        self.hud = hud
        self.currentWorkspace = currentWorkspace
        self.apply = apply
    }

    /// *Toggle layout*: cycles the current workspace through Auto-tile, Zones and Free by writing its layout kind
    /// override (every kind's state is kept, so cycling is lossless); a kind equal to the default clears the
    /// override. Does nothing when the stored overrides come from a newer version (they are never overwritten).
    func toggleLayout() async {
        guard trust.refresh() else {
            hud.show(.accessibilityNeeded(.moving))
            return
        }
        guard let workspace = currentWorkspace() else { return }
        var overrides = settings.workspaceOverrides
        guard !overrides.isReadOnly else { return }
        let current = overrides.byWorkspace[workspace]?.kind ?? settings.defaultKind
        let next = Self.nextKind(after: current)
        var entry = overrides.byWorkspace[workspace] ?? WorkspaceOverride()
        entry.kind = next == settings.defaultKind ? nil : next
        overrides.byWorkspace[workspace] = entry.isEmpty ? nil : entry
        settings.setWorkspaceOverrides(overrides)
        await apply()
        context.resultsChanged()
    }

    /// A layout slot command: the layout bound to the slot becomes the layout of the current workspace on the
    /// display of the focused window. An unbound slot does nothing.
    func applyLayoutSlot(_ number: Int) async {
        guard let layoutID = await layouts.slots[number] else { return }
        await useLayout(layoutID)
    }

    /// *Next zone layout*: the layout after the one in effect, over the stock templates and then the user's.
    func nextLayout() async {
        guard let cell = await currentCell() else { return }
        let library = await layouts.library
        let config = WindowsRuntime.config(settings, assignments: await assignments.table, library: library).zones
        let displays = await context.windows.displays()
        let keyed = DisplayKeys.keys(for: displays)
        let orientation = displays.first { keyed.keys[$0.id] == cell.displayKey }?.orientation ?? .landscape
        let current = config.resolve(workspace: cell.workspace, displayKey: cell.displayKey, orientation: orientation)
        guard let next = library.next(after: current.layout.id) else { return }
        await useLayout(next)
    }

    private func currentCell() async -> (workspace: WorkspaceID, displayKey: String)? {
        let summary = await engine.switcherState().summary
        guard let workspace = summary.current, let display = summary.focusedDisplay else { return nil }
        return (workspace, display)
    }

    private func useLayout(_ layoutID: String) async {
        guard trust.refresh() else {
            hud.show(.accessibilityNeeded(.moving))
            return
        }
        guard let cell = await currentCell() else { return }
        do {
            try await assignments.set(layoutID, workspace: cell.workspace, displayKey: cell.displayKey)
        } catch {
            context.logger.error("Cannot write assignments.json")
            return
        }
        await apply()
        context.resultsChanged()
    }

    /// Auto-tile, then Zones, then Free, then Auto-tile again.
    static func nextKind(after kind: LayoutKind) -> LayoutKind {
        switch kind {
        case .tiling: .zones
        case .zones: .free
        case .free: .tiling
        }
    }
}
