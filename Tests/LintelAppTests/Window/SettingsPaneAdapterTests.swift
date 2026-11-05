import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, step 1.3: the old Settings panes inside the main window's Settings mode.
@Suite struct SettingsPaneAdapterTests {
    private func plugins() -> [SettingsWindowController.PluginPane] {
        [
            .init(id: "apps", title: "Apps", symbolName: "app", view: AnyView(EmptyView())),
            .init(id: "clipboard", title: "Clipboard", symbolName: "doc", view: AnyView(EmptyView()), isActive: false),
        ]
    }

    private func entries() -> [SettingsPaneAdapter.Entry] {
        SettingsPaneAdapter.entries(shellPane: { _ in AnyView(EmptyView()) }, plugins: plugins())
    }

    @Test func theEntriesFollowTheOrderOfTheOldWindow() {
        #expect(
            entries().map(\.id) == ["general", "features", "apps", "clipboard", "permissions", "advanced"])
    }

    @Test func everyShellPaneAndEveryPluginPaneIsReachable() {
        let ids = Set(entries().map(\.id))
        for pane in SettingsWindowController.Pane.allCases { #expect(ids.contains(pane.rawValue)) }
        #expect(ids.isSuperset(of: ["apps", "clipboard"]))
    }

    @Test func anInactivePluginPaneIsMarkedAndStillReachable() {
        let entry = entries().first { $0.id == "clipboard" }
        #expect(entry?.isActive == false)
    }

    @Test func aShellPaneIsBuiltOnlyWhenShown() {
        var built: [SettingsWindowController.Pane] = []
        let entries = SettingsPaneAdapter.entries(
            shellPane: { pane in
                built.append(pane)
                return AnyView(EmptyView())
            }, plugins: [])
        #expect(built.isEmpty)
        _ = entries.first { $0.id == "advanced" }?.makeView()
        #expect(built == [.advanced])
    }

    @Test func selectingAPaneUpdatesAndStoresTheState() {
        let store = InMemorySettingsStore([:])
        let ids = entries().map(\.id)
        let controller = MainWindowController(
            settings: store, sections: { [] }, settingsPanes: { ids }, screens: { [] }, frameAutosaveName: nil,
            makeContent: { _, _ in AnyView(EmptyView()) })
        controller.activatesApp = false
        controller.showSettings("features")
        for id in ids {
            controller.selectSettingsPane(id)
            #expect(controller.state?.settingsPane == id)
            #expect(store.value(forKey: SettingsKeys.mainWindowSettingsPane) == .string(id))
        }
        controller.selectSettingsPane("bogus")
        #expect(controller.state?.settingsPane == "advanced")
        controller.close()
    }

    @Test func theQASettingsArgumentStillParsesAlongsideTheWindow() throws {
        let options = try QAOptions.parse(["--qa", "--qa-settings", "clipboard", "--qa-window", "settings"])
        #expect(options?.settingsPane == "clipboard")
        #expect(options?.windowMode == .settings)
        #expect(try QAOptions.parse(["--qa", "--qa-settings", "general"])?.settingsPane == "general")
    }
}
