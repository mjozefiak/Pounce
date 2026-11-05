import LintelKit

/// Sends the shell's ways into Lintel's windows (Dock click, Command-comma, the status item's "Settings…",
/// `PluginContext.openModels` and `openNote` routes) to the main window (spec `2026-11-04-lintel-main-window`,
/// step 1.5; ADR 0008, "Release gate").
///
/// The window is enabled in every build since step 6.3a (`ReleaseGateTests`). Pure apart from the injected targets,
/// so tests drive it with recording closures.
final class MainWindowRouter {
    /// The Models pane's id in the main window's Settings mode (`ModelsPane`, step 3.2); `pendingModelsPackageID`
    /// keeps the row the pane scrolls to.
    static let modelsPaneID = "models"

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
    }

    private let targets: Targets

    /// The package an `openModels` asked for; the Models pane scrolls to its row and clears it.
    private(set) var pendingModelsPackageID: String?

    init(targets: Targets) {
        self.targets = targets
    }

    /// A click on the Dock icon, or opening the app again from Finder: the main window unless a real window is
    /// visible. The launcher panel and HUDs do not count (`DockPresence.hasVisibleWindows`), so AppKit's own answer,
    /// which counts them, is not used.
    func reopen(visibleWindowRoles: [KeyWindowRole]) {
        let hasVisible = DockPresence.hasVisibleWindows(visibleWindowRoles)
        guard DockPresence.reopenAction(hasVisibleWindows: hasVisible) == .openMainWindow else { return }
        targets.showMainWindow()
    }

    /// The welcome screen's final page: the main window in its restored state.
    func openMainWindow() {
        targets.showMainWindow()
    }

    /// Command-comma and the status item's "Settings…": Settings mode of the main window on the stored pane.
    func openSettings() {
        targets.showMainWindowSettings(nil)
    }

    /// A shell or plugin pane of Settings mode (the panel's "Open Settings", `PluginContext.openSettings`).
    func openSettings(pane paneID: String) {
        targets.showMainWindowSettings(paneID)
    }

    /// `PluginContext.openModels`: the Models pane, scrolled to the package's row.
    func openModels(packageID: String?) {
        pendingModelsPackageID = packageID
        targets.showMainWindowSettings(Self.modelsPaneID)
    }

    /// Hands the pending package to the Models pane once.
    func takePendingModelsPackageID() -> String? {
        defer { pendingModelsPackageID = nil }
        return pendingModelsPackageID
    }

    /// An `openNote` route: the first section that handles it is shown in Workspace mode. Returns `false` when no
    /// section handled it (none is registered yet), so the caller keeps its old behaviour (Meetings opens its own
    /// window).
    @discardableResult
    func open(_ route: WorkspaceRoute) -> Bool {
        guard let section = targets.sections().first(where: { $0.handleRoute(route) }) else { return false }
        targets.showMainWindowSection(section.id)
        return true
    }
}
