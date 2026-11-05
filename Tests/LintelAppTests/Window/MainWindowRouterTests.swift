import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 1.5: Dock, Command-comma, "Settings…", `openModels` and `openNote`
/// routes. The window is enabled in every build since step 6.3a (ADR 0008 "Release gate", `ReleaseGateTests`).
@MainActor @Suite struct MainWindowRouterTests {
    /// Every call the router made, in order.
    final class Recorder {
        var calls: [String] = []
    }

    /// The speech model's package id in the catalog (`ModelCatalog`, `LintelSpeech`).
    static let parakeet = "parakeet-ultra"

    private func router(sections: [WorkspaceSection] = []) -> (MainWindowRouter, Recorder) {
        let recorder = Recorder()
        var targets = MainWindowRouter.Targets()
        targets.showMainWindow = { recorder.calls.append("window") }
        targets.showMainWindowSettings = { recorder.calls.append("window.settings:\($0 ?? "stored")") }
        targets.showMainWindowSection = { recorder.calls.append("window.section:\($0)") }
        targets.sections = { sections }
        return (MainWindowRouter(targets: targets), recorder)
    }

    private func section(_ id: String, handles kind: String?, log: Recorder? = nil) -> WorkspaceSection {
        WorkspaceSection(
            id: id, title: "Section", symbolName: "doc", order: 0, makeView: { AnyView(EmptyView()) },
            handleRoute: { route in
                log?.calls.append("route:\(id)")
                return route.kind == kind
            })
    }

    // MARK: The main window (every build since step 6.3a)

    @Test func theDockIgnoresAppKitsAnswer() {
        // AppKit counts the launcher panel as a visible window; the router decides from the roles only.
        let (router, recorder) = router()
        router.reopen(visibleWindowRoles: [.launcherPanel])
        #expect(recorder.calls == ["window"])
    }

    @Test func shellAndPluginPanesOpenInSettingsMode() {
        let (router, recorder) = router()
        router.openSettings(pane: SettingsWindowController.Pane.features.rawValue)
        router.openSettings(pane: "dictation")
        #expect(recorder.calls == ["window.settings:features", "window.settings:dictation"])
    }

    @Test func theDockOpensTheMainWindowWhenOnlyTheLauncherPanelIsVisible() {
        let (router, recorder) = router()
        router.reopen(visibleWindowRoles: [.launcherPanel])
        router.reopen(visibleWindowRoles: [.launcherPanel, .hud])
        router.reopen(visibleWindowRoles: [])
        #expect(recorder.calls == ["window", "window", "window"])
    }

    @Test func theDockLeavesAnOpenWindowAlone() {
        let (router, recorder) = router()
        router.reopen(visibleWindowRoles: [.mainWindow])
        router.reopen(visibleWindowRoles: [.launcherPanel, .other])
        #expect(recorder.calls.isEmpty)
    }

    @Test func settingsOpensSettingsModeOnTheStoredPane() {
        let (router, recorder) = router()
        router.openSettings()
        #expect(recorder.calls == ["window.settings:stored"])
    }

    @Test func openModelsOpensTheModelsPaneOnThePackagesRow() {
        let (router, recorder) = router()
        router.openModels(packageID: Self.parakeet)
        #expect(recorder.calls == ["window.settings:\(MainWindowRouter.modelsPaneID)"])
        #expect(router.pendingModelsPackageID == Self.parakeet)
        #expect(router.takePendingModelsPackageID() == Self.parakeet)
        #expect(router.takePendingModelsPackageID() == nil)
    }

    @Test func openModelsWithoutAPackageOpensTheModelsPaneWithoutARow() {
        let (router, recorder) = router()
        router.openModels(packageID: Self.parakeet)
        router.openModels(packageID: nil)
        #expect(recorder.calls == ["window.settings:models", "window.settings:models"])
        #expect(router.pendingModelsPackageID == nil)
    }

    @Test func theModelsPaneIDIsStable() {
        #expect(MainWindowRouter.modelsPaneID == "models")
    }

    @Test func aRouteShowsTheFirstSectionThatHandlesIt() {
        let log = Recorder()
        let sections = [
            section("other", handles: "openOther", log: log), section("notes", handles: "openNote", log: log),
            section("later", handles: "openNote", log: log),
        ]
        let (router, recorder) = router(sections: sections)
        #expect(router.open(WorkspaceRoute(kind: "openNote", id: "meetings:1")))
        #expect(log.calls == ["route:other", "route:notes"])
        #expect(recorder.calls == ["window.section:notes"])
    }

    @Test func anUnhandledRouteShowsNothing() {
        let (router, recorder) = router(sections: [section("notes", handles: "openNote")])
        #expect(!router.open(WorkspaceRoute(kind: "openSomething", id: "x")))
        let (empty, emptyRecorder) = self.router()
        #expect(!empty.open(WorkspaceRoute(kind: "openNote", id: "x")))
        #expect(recorder.calls.isEmpty)
        #expect(emptyRecorder.calls.isEmpty)
    }

    @Test func contextsReachTheShellsOpenModels() throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let recorder = Recorder()
        let context = test.environment.makeContext(
            for: PluginManifest(id: "dictation", displayName: "Dictation", symbolName: "mic", order: 40),
            openModels: { recorder.calls.append($0 ?? "none") })
        context.openModels(Self.parakeet)
        context.openModels(nil)
        #expect(recorder.calls == [Self.parakeet, "none"])
    }
}
