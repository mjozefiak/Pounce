import Foundation

extension EngineConfig {
    /// The configuration the plugin's settings and stored data describe. The kind-independent part is read here;
    /// every strategy builds its own configuration (`LayoutStrategy.makeConfig`), so a new kind needs no change.
    init(
        settings: WindowsSettings, registry: LayoutRegistry, assignments: AssignmentTable = AssignmentTable(),
        library: LayoutLibrary = .stock
    ) {
        self.init()
        followFocus = settings.followFocus
        floatingBundleIDs = Set(settings.floatingApps)
        layout = LayoutConfig(
            defaultKind: settings.defaultKind(in: registry), innerGap: settings.innerGap, outerGap: settings.outerGap,
            rootOrientation: .horizontal, overrides: settings.workspaceOverrides(in: registry).byWorkspace)
        strategyConfigs = registry.configs(
            LayoutEnvironment(settings: settings, assignments: assignments, library: library))
    }
}
