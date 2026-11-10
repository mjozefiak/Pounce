import Foundation
import LintelKit

/// The commands that change which layout a workspace uses: *Toggle layout*, the nine layout slots and *Next zone
/// layout*. They write settings or assignments and then ask the runtime to apply them; every one is behind the
/// Accessibility gate, because the windows are placed again.
@MainActor
final class LayoutCommands {
    private let settings: WindowsSettings
    private let registry: LayoutRegistry
    private let assignments: AssignmentStore
    private let layouts: LayoutRepository
    private let engine: WindowEngine
    private let gate: AccessibilityGate
    private let context: PluginContext
    private let currentWorkspace: @MainActor () -> WorkspaceID?
    private let apply: @MainActor () async -> Void

    init(
        context: PluginContext, settings: WindowsSettings, registry: LayoutRegistry, assignments: AssignmentStore,
        layouts: LayoutRepository,
        engine: WindowEngine, gate: AccessibilityGate,
        currentWorkspace: @escaping @MainActor () -> WorkspaceID?, apply: @escaping @MainActor () async -> Void
    ) {
        self.context = context
        self.settings = settings
        self.registry = registry
        self.assignments = assignments
        self.layouts = layouts
        self.engine = engine
        self.gate = gate
        self.currentWorkspace = currentWorkspace
        self.apply = apply
    }

    /// *Toggle layout*: cycles the current workspace through Auto-tile, Zones and Free by writing its layout kind
    /// override (every kind's state is kept, so cycling is lossless); a kind equal to the default clears the
    /// override. Does nothing when the stored overrides come from a newer version (they are never overwritten).
    func toggleLayout() async {
        guard gate.allows(.moving), let workspace = currentWorkspace() else { return }
        // Written from the raw overrides, so a kind this build does not know stays in the stored value.
        var overrides = settings.workspaceOverrides
        guard !overrides.isReadOnly else { return }
        let defaultKind = settings.defaultKind(in: registry)
        let current = settings.workspaceOverrides(in: registry).byWorkspace[workspace]?.kind ?? defaultKind
        let next = registry.kind(after: current)
        var entry = overrides.byWorkspace[workspace] ?? WorkspaceOverride()
        entry.kind = next == defaultKind ? nil : next
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

    /// *Next zone layout*: the layout after the one in effect, over the stock templates and then the user's. The
    /// kind that uses the library says which layout is in effect (`LayoutLibraryProviding.libraryLayoutID`): the kind of
    /// the current workspace when it uses the library, else the first registered kind that does.
    func nextLayout() async {
        guard let cell = await currentCell() else { return }
        let layoutLibrary = await layouts.library
        let environment = LayoutEnvironment(
            settings: settings, assignments: await assignments.table, library: layoutLibrary)
        let kind = await currentKind(of: cell.workspace)
        guard let provider = registry[kind]?.library ?? libraryStrategy?.library else { return }
        let displays = await context.windows.displays()
        let keyed = DisplayKeys.keys(for: displays)
        let orientation = displays.first { keyed.keys[$0.id] == cell.displayKey }?.orientation ?? .landscape
        let current = provider.libraryLayoutID(
            environment, workspace: cell.workspace, displayKey: cell.displayKey, orientation: orientation)
        guard let next = layoutLibrary.next(after: current) else { return }
        await useLayout(next)
    }

    private var libraryStrategy: (any LayoutStrategy)? {
        registry.libraryKinds.first.flatMap { registry[$0] }
    }

    /// The kind the workspace uses now: its override, else the default.
    private func currentKind(of workspace: WorkspaceID) async -> LayoutKind {
        LayoutConfig(settings: settings, registry: registry).resolved(for: workspace).kind
    }

    private func currentCell() async -> (workspace: WorkspaceID, displayKey: String)? {
        let summary = await engine.summary()
        guard let workspace = summary.current, let display = summary.focusedDisplay else { return nil }
        return (workspace, display)
    }

    private func useLayout(_ layoutID: String) async {
        guard gate.allows(.moving), let cell = await currentCell() else { return }
        do {
            try await assignments.set(layoutID, workspace: cell.workspace, displayKey: cell.displayKey)
        } catch {
            context.logger.error("Cannot write assignments.json")
            return
        }
        await apply()
        context.resultsChanged()
    }
}
