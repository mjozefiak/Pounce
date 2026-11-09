import Foundation

/// Builds the engine's configuration from the plugin's settings and stored data. The kind-independent part is read
/// here; every strategy builds its own configuration (`LayoutStrategy.makeConfig`), so a new kind needs no change.
struct EngineConfigBuilder: Sendable {
    var registry: LayoutRegistry = .standard

    func build(
        _ settings: WindowsSettings, assignments: AssignmentTable = AssignmentTable(),
        library: LayoutLibrary = .stock
    ) -> EngineConfig {
        var config = EngineConfig()
        config.followFocus = settings.followFocus
        config.floatingBundleIDs = Set(settings.floatingApps)
        config.layout = LayoutConfig(
            defaultKind: settings.defaultKind, innerGap: settings.innerGap, outerGap: settings.outerGap,
            rootOrientation: .horizontal, overrides: settings.workspaceOverrides.byWorkspace)
        config.strategyConfigs = registry.configs(
            LayoutEnvironment(settings: settings, assignments: assignments, library: library))
        return config
    }
}
