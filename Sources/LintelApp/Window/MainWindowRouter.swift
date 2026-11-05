import LintelKit

/// Sends the shell's ways into Lintel's windows (Dock click, Command-comma, the status item's "Settings…",
/// `PluginContext.openModels` and `openNote` routes) to the main window while it is enabled, and to the old
/// `SettingsWindowController` otherwise (spec `2026-11-04-lintel-main-window`, step 1.5; ADR 0008, "Release gate").
///
/// **Window enabled** is `#if DEBUG` until step 6.3a and every build after it (`isWindowEnabledInThisBuild`). While it
/// is not enabled, every route behaves exactly as before the main window existed. Pure apart from the injected
/// targets, so tests drive it with recording closures.
final class MainWindowRouter {
    /// The Models pane's id in the main window's Settings mode. The pane itself arrives with step 3.2, whose sidebar
    /// lists it under this id; until then `MainWindowController.showSettings` treats it as unknown and opens General,
    /// and `pendingModelsPackageID` keeps the row the pane scrolls to.
    static let modelsPaneID = "models"

    /// The release gate of ADR 0008: true in DEBUG builds only, until step 6.3a removes the gate.
    static var isWindowEnabledInThisBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The model packages one active plugin uses (`LintelPlugin.modelUsage`), in plugin order.
    struct ModelUser: Equatable {
        let pluginID: String
        let packageIDs: [String]
    }

    /// Where the routes end.
    struct Targets {
        /// The main window in its restored state (Settings mode while no section exists).
        var showMainWindow: () -> Void = {}
        /// The main window in Settings mode on a pane; `nil` keeps the stored pane.
        var showMainWindowSettings: (_ paneID: String?) -> Void = { _ in }
        /// The main window in Workspace mode on a section.
        var showMainWindowSection: (_ sectionID: String) -> Void = { _ in }
        /// The active plugins' workspace sections, in order.
        var sections: () -> [WorkspaceSection] = { [] }
        /// The old Settings window on a shell pane.
        var showLegacySettings: (SettingsWindowController.Pane) -> Void = { _ in }
        /// The old Settings window on a plugin's own pane.
        var showLegacyPluginPane: (_ pluginID: String) -> Void = { _ in }
        /// The active plugins' model usages, in plugin order.
        var modelUsers: () -> [ModelUser] = { [] }
    }

    let isWindowEnabled: Bool
    private let targets: Targets

    /// The package an `openModels` asked for while the window is enabled; the Models pane (step 3.2) scrolls to its
    /// row and clears it.
    private(set) var pendingModelsPackageID: String?

    init(isWindowEnabled: Bool = MainWindowRouter.isWindowEnabledInThisBuild, targets: Targets) {
        self.isWindowEnabled = isWindowEnabled
        self.targets = targets
    }

    /// A click on the Dock icon, or opening the app again from Finder.
    ///
    /// - Parameters:
    ///   - appKitHasVisibleWindows: AppKit's own answer, which counts the launcher panel and HUDs; used while the
    ///     window is not enabled, as before.
    ///   - visibleWindowRoles: the roles of the visible windows; while the window is enabled only real windows count
    ///     (`DockPresence.hasVisibleWindows`).
    func reopen(appKitHasVisibleWindows: Bool, visibleWindowRoles: [KeyWindowRole]) {
        let hasVisible =
            isWindowEnabled ? DockPresence.hasVisibleWindows(visibleWindowRoles) : appKitHasVisibleWindows
        guard DockPresence.reopenAction(hasVisibleWindows: hasVisible) == .openMainWindow else { return }
        if isWindowEnabled {
            targets.showMainWindow()
        } else {
            targets.showLegacySettings(.general)
        }
    }

    /// Command-comma and the status item's "Settings…": Settings mode of the main window, or the old window.
    func openSettings() {
        if isWindowEnabled {
            targets.showMainWindowSettings(nil)
        } else {
            targets.showLegacySettings(.general)
        }
    }

    /// `PluginContext.openModels` of the plugin `callerID`.
    ///
    /// While the window is enabled: the Models pane, scrolled to the package's row. Otherwise the old window on the
    /// pane that still shows the model card: the caller's when its `modelUsage` lists the package (or for `nil`),
    /// else the first active plugin that lists it, else the caller's.
    func openModels(from callerID: String, packageID: String?) {
        if isWindowEnabled {
            pendingModelsPackageID = packageID
            targets.showMainWindowSettings(Self.modelsPaneID)
            return
        }
        let pane = Self.legacyModelsPane(caller: callerID, packageID: packageID, users: targets.modelUsers())
        targets.showLegacyPluginPane(pane)
    }

    /// Hands the pending package to the Models pane once.
    func takePendingModelsPackageID() -> String? {
        defer { pendingModelsPackageID = nil }
        return pendingModelsPackageID
    }

    /// The plugin pane of the old window that shows the model card for `packageID`.
    static func legacyModelsPane(caller: String, packageID: String?, users: [ModelUser]) -> String {
        guard let packageID else { return caller }
        if users.contains(where: { $0.pluginID == caller && $0.packageIDs.contains(packageID) }) { return caller }
        return users.first { $0.packageIDs.contains(packageID) }?.pluginID ?? caller
    }

    /// An `openNote` route: while the window is enabled, the first section that handles it is shown in Workspace
    /// mode. Returns `false` when no section handled it, and always while the window is not enabled, so the caller
    /// keeps its old behaviour (Meetings opens its own window).
    @discardableResult
    func open(_ route: WorkspaceRoute) -> Bool {
        guard isWindowEnabled else { return false }
        guard let section = targets.sections().first(where: { $0.handleRoute(route) }) else { return false }
        targets.showMainWindowSection(section.id)
        return true
    }
}
