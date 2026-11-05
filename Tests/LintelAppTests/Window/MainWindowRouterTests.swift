import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 1.5: Dock, Command-comma, "Settings…", `openModels` and `openNote`
/// routes, with the window enabled (DEBUG) and not enabled (release, ADR 0008 "Release gate").
@MainActor @Suite struct MainWindowRouterTests {
    /// Every call the router made, in order.
    final class Recorder {
        var calls: [String] = []
    }

    /// The speech model's package id in the catalog (`ModelCatalog`, `LintelSpeech`).
    static let parakeet = "parakeet-ultra"

    /// Fake usages: `ModelUsage` declarations of Dictation and Meetings arrive with step 3.2.
    static let users = [
        MainWindowRouter.ModelUser(pluginID: "clipboard", packageIDs: []),
        MainWindowRouter.ModelUser(pluginID: "dictation", packageIDs: [parakeet, "qwen"]),
        MainWindowRouter.ModelUser(pluginID: "meetings", packageIDs: [parakeet, "diarization-community-1"]),
    ]

    private func router(
        enabled: Bool, sections: [WorkspaceSection] = [], users: [MainWindowRouter.ModelUser] = users
    ) -> (MainWindowRouter, Recorder) {
        let recorder = Recorder()
        var targets = MainWindowRouter.Targets()
        targets.showMainWindow = { recorder.calls.append("window") }
        targets.showMainWindowSettings = { recorder.calls.append("window.settings:\($0 ?? "stored")") }
        targets.showMainWindowSection = { recorder.calls.append("window.section:\($0)") }
        targets.sections = { sections }
        targets.showLegacySettings = { recorder.calls.append("legacy:\($0.rawValue)") }
        targets.showLegacyPluginPane = { recorder.calls.append("legacy.plugin:\($0)") }
        targets.modelUsers = { users }
        return (MainWindowRouter(isWindowEnabled: enabled, targets: targets), recorder)
    }

    private func section(_ id: String, handles kind: String?, log: Recorder? = nil) -> WorkspaceSection {
        WorkspaceSection(
            id: id, title: "Section", symbolName: "doc", order: 0, makeView: { AnyView(EmptyView()) },
            handleRoute: { route in
                log?.calls.append("route:\(id)")
                return route.kind == kind
            })
    }

    @Test func theWindowIsEnabledOnlyInDebugBuilds() {
        #if DEBUG
        #expect(MainWindowRouter.isWindowEnabledInThisBuild)
        #else
        #expect(!MainWindowRouter.isWindowEnabledInThisBuild)
        #endif
    }

    // MARK: Not enabled: today's behaviour

    @Test func withoutTheWindowTheDockOpensTheOldSettingsAsToday() {
        let (router, recorder) = router(enabled: false)
        router.reopen(appKitHasVisibleWindows: false, visibleWindowRoles: [])
        router.reopen(appKitHasVisibleWindows: true, visibleWindowRoles: [.other])
        #expect(recorder.calls == ["legacy:general"])
    }

    @Test func withoutTheWindowAppKitsAnswerIsKept() {
        // AppKit counts the launcher panel; the release build keeps doing what it did.
        let (router, recorder) = router(enabled: false)
        router.reopen(appKitHasVisibleWindows: true, visibleWindowRoles: [.launcherPanel])
        #expect(recorder.calls.isEmpty)
    }

    @Test func withoutTheWindowSettingsOpensTheOldWindow() {
        let (router, recorder) = router(enabled: false)
        router.openSettings()
        #expect(recorder.calls == ["legacy:general"])
    }

    @Test func withoutTheWindowOpenModelsSelectsTheDictationPaneInTheOldWindow() {
        let (router, recorder) = router(enabled: false)
        router.openModels(from: "dictation", packageID: Self.parakeet)
        #expect(recorder.calls == ["legacy.plugin:dictation"])
        #expect(router.pendingModelsPackageID == nil)
    }

    @Test func withoutTheWindowOpenModelsPrefersTheCallersPane() {
        let (router, recorder) = router(enabled: false)
        router.openModels(from: "meetings", packageID: Self.parakeet)
        router.openModels(from: "meetings", packageID: "diarization-community-1")
        #expect(recorder.calls == ["legacy.plugin:meetings", "legacy.plugin:meetings"])
    }

    @Test func withoutTheWindowOpenModelsFallsBackToTheFirstPluginThatListsThePackage() {
        let (router, recorder) = router(enabled: false)
        router.openModels(from: "clipboard", packageID: Self.parakeet)
        router.openModels(from: "meetings", packageID: "qwen")
        #expect(recorder.calls == ["legacy.plugin:dictation", "legacy.plugin:dictation"])
    }

    @Test func withoutTheWindowOpenModelsWithoutAPackageOpensTheCallersPane() {
        let (router, recorder) = router(enabled: false)
        router.openModels(from: "meetings", packageID: nil)
        router.openModels(from: "clipboard", packageID: "unknown")
        #expect(recorder.calls == ["legacy.plugin:meetings", "legacy.plugin:clipboard"])
    }

    @Test func withoutTheWindowNoRouteIsHandled() {
        let log = Recorder()
        let (router, recorder) = router(enabled: false, sections: [section("notes", handles: "openNote", log: log)])
        #expect(!router.open(WorkspaceRoute(kind: "openNote", id: "meetings:1")))
        #expect(log.calls.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    // MARK: Enabled: the main window

    @Test func theDockOpensTheMainWindowWhenOnlyTheLauncherPanelIsVisible() {
        let (router, recorder) = router(enabled: true)
        router.reopen(appKitHasVisibleWindows: true, visibleWindowRoles: [.launcherPanel])
        router.reopen(appKitHasVisibleWindows: true, visibleWindowRoles: [.launcherPanel, .hud])
        router.reopen(appKitHasVisibleWindows: false, visibleWindowRoles: [])
        #expect(recorder.calls == ["window", "window", "window"])
    }

    @Test func theDockLeavesAnOpenWindowAlone() {
        let (router, recorder) = router(enabled: true)
        router.reopen(appKitHasVisibleWindows: true, visibleWindowRoles: [.mainWindow])
        router.reopen(appKitHasVisibleWindows: true, visibleWindowRoles: [.launcherPanel, .other])
        #expect(recorder.calls.isEmpty)
    }

    @Test func settingsOpensSettingsModeOnTheStoredPane() {
        let (router, recorder) = router(enabled: true)
        router.openSettings()
        #expect(recorder.calls == ["window.settings:stored"])
    }

    @Test func openModelsOpensTheModelsPaneOnThePackagesRow() {
        let (router, recorder) = router(enabled: true)
        router.openModels(from: "dictation", packageID: Self.parakeet)
        #expect(recorder.calls == ["window.settings:\(MainWindowRouter.modelsPaneID)"])
        #expect(router.pendingModelsPackageID == Self.parakeet)
        #expect(router.takePendingModelsPackageID() == Self.parakeet)
        #expect(router.takePendingModelsPackageID() == nil)
    }

    @Test func openModelsWithoutAPackageOpensTheModelsPaneWithoutARow() {
        let (router, recorder) = router(enabled: true)
        router.openModels(from: "meetings", packageID: Self.parakeet)
        router.openModels(from: "meetings", packageID: nil)
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
        let (router, recorder) = router(enabled: true, sections: sections)
        #expect(router.open(WorkspaceRoute(kind: "openNote", id: "meetings:1")))
        #expect(log.calls == ["route:other", "route:notes"])
        #expect(recorder.calls == ["window.section:notes"])
    }

    @Test func anUnhandledRouteShowsNothing() {
        let (router, recorder) = router(enabled: true, sections: [section("notes", handles: "openNote")])
        #expect(!router.open(WorkspaceRoute(kind: "openSomething", id: "x")))
        let (empty, emptyRecorder) = self.router(enabled: true)
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
