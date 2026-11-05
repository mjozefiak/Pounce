import LintelKit
import SwiftUI
import Testing

@testable import LintelApp

/// Spec `2026-11-04-lintel-main-window`, steps 1.3 and 6.3b: the panes of the main window's Settings mode.
@Suite struct SettingsPanesTests {
    private func plugins() -> [SettingsPluginPane] {
        [
            .init(id: "apps", title: "Apps", symbolName: "app", view: AnyView(EmptyView())),
            .init(id: "clipboard", title: "Clipboard", symbolName: "doc", view: AnyView(EmptyView()), isActive: false),
        ]
    }

    private func entries() -> [SettingsPanes.Entry] {
        SettingsPanes.entries(shellPane: { _ in AnyView(EmptyView()) }, plugins: plugins())
    }

    @Test func everyPaneOfTheSidebarHasAnEntry() {
        let sections = SettingsPanes.sidebarSections(plugins: plugins())
        let ids = Set(entries().map(\.id))
        for id in SettingsSidebarModel.focusOrder(sections) { #expect(ids.contains(id)) }
    }

    @Test func everyShellPaneAndEveryPluginPaneIsReachable() {
        let ids = Set(entries().map(\.id))
        for pane in SettingsShellPane.allCases { #expect(ids.contains(pane.rawValue)) }
        #expect(ids.isSuperset(of: ["apps", "clipboard", "models"]))
    }

    @Test func anInactivePluginPaneIsMarkedAndStillReachable() {
        let entry = entries().first { $0.id == "clipboard" }
        #expect(entry?.isActive == false)
    }

    @Test func aShellPaneIsBuiltOnlyWhenShown() {
        var built: [SettingsShellPane] = []
        let entries = SettingsPanes.entries(
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
        #expect(controller.state?.settingsPane == ids.last)
        controller.close()
    }

    @Test func theQASettingsArgumentStillParsesAlongsideTheWindow() throws {
        let options = try QAOptions.parse(["--qa", "--qa-settings", "clipboard", "--qa-window", "settings"])
        #expect(options?.settingsPane == "clipboard")
        #expect(options?.windowMode == .settings)
        #expect(try QAOptions.parse(["--qa", "--qa-settings", "general"])?.settingsPane == "general")
    }
}
