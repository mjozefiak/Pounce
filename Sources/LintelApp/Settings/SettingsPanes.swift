import LintelKit
import SwiftUI

/// The shell's own panes of the main window's Settings mode. The raw values are the pane ids that
/// `app.mainWindow.settingsPane` stores and `--qa-settings` takes.
enum SettingsShellPane: String, CaseIterable {
    case general
    case features
    case permissions
    case advanced
}

/// A plugin's own Settings pane (`LintelPlugin.settingsPane()`), as the sidebar lists it.
struct SettingsPluginPane {
    let id: String
    let title: String
    let symbolName: String
    let view: AnyView
    /// False for the pane of a disabled or failed plugin, which the main window shows dimmed.
    var isActive = true
    /// The sidebar group, from `manifest.settingsGroup`, and the order inside it, from `manifest.order`.
    var group: SettingsGroup = .lintel
    var order = 0
}

/// The panes of Settings mode by id and the sidebar built from them.
enum SettingsPanes {
    struct Entry {
        let id: String
        let title: String
        let symbolName: String
        /// False for the pane of a disabled or failed plugin.
        let isActive: Bool
        /// Built on selection only, so a pane that is not shown costs nothing.
        let makeView: () -> AnyView
    }

    /// The entries by id; the sidebar (`SettingsSidebarModel`) decides the order. `models` draws Settings → Models;
    /// without it the entry is empty.
    static func entries(
        shellPane: @escaping (SettingsShellPane) -> AnyView,
        plugins: [SettingsPluginPane],
        models: (() -> AnyView)? = nil
    ) -> [Entry] {
        func shell(_ pane: SettingsShellPane) -> Entry {
            Entry(id: pane.rawValue, title: pane.rawValue, symbolName: "", isActive: true) { shellPane(pane) }
        }
        let pluginEntries = plugins.map { pane in
            Entry(id: pane.id, title: pane.title, symbolName: pane.symbolName, isActive: pane.isActive) { pane.view }
        }
        let models = Entry(
            id: SettingsSidebarModel.modelsID, title: SettingsSidebarModel.modelsID, symbolName: "", isActive: true
        ) {
            models?() ?? AnyView(EmptyView())
        }
        return SettingsShellPane.allCases.map(shell) + pluginEntries + [models]
    }

    /// The sidebar's input from the plugins' panes and each pane's attention level (`SettingsHostModel`), plugin and
    /// shell panes alike.
    static func sidebarSections(
        plugins: [SettingsPluginPane], attention: [String: SettingsStatus.Level] = [:]
    ) -> [SettingsSidebarModel.Section] {
        SettingsSidebarModel.sections(
            plugins: plugins.map {
                SettingsSidebarModel.PluginItem(
                    id: $0.id, title: $0.title, symbolName: $0.symbolName, group: $0.group, order: $0.order,
                    isActive: $0.isActive, attention: attention[$0.id])
            },
            shellAttention: attention)
    }
}
