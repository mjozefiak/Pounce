import SwiftUI

/// Temporary adapter (spec `2026-11-04-lintel-main-window`, step 1.3): shows the panes of the old Settings window
/// unchanged inside the main window's Settings mode, listed by the sidebar of step 2.1. The pane template
/// replaces it in steps 2.2 and 2.3.
enum SettingsPaneAdapter {
    struct Entry {
        let id: String
        let title: String
        let symbolName: String
        /// False for the pane of a disabled or failed plugin.
        let isActive: Bool
        /// Built on selection only, so a pane that is not shown costs nothing.
        let makeView: () -> AnyView
    }

    /// The entries by id; the sidebar (`SettingsSidebarModel`) decides the order. The Models pane stays a
    /// placeholder until step 3.2.
    static func entries(
        shellPane: @escaping (SettingsWindowController.Pane) -> AnyView,
        plugins: [SettingsWindowController.PluginPane]
    ) -> [Entry] {
        func shell(_ pane: SettingsWindowController.Pane) -> Entry {
            Entry(id: pane.rawValue, title: pane.rawValue, symbolName: "", isActive: true) { shellPane(pane) }
        }
        let pluginEntries = plugins.map { pane in
            Entry(id: pane.id, title: pane.title, symbolName: pane.symbolName, isActive: pane.isActive) { pane.view }
        }
        let models = Entry(
            id: SettingsSidebarModel.modelsID, title: SettingsSidebarModel.modelsID, symbolName: "", isActive: true
        ) {
            AnyView(
                Text(String(localized: "Models", comment: "Settings pane title"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity))
        }
        return SettingsWindowController.Pane.allCases.map(shell) + pluginEntries + [models]
    }

    /// The sidebar's input from the plugins' panes.
    static func sidebarSections(plugins: [SettingsWindowController.PluginPane]) -> [SettingsSidebarModel.Section] {
        SettingsSidebarModel.sections(
            plugins: plugins.map {
                SettingsSidebarModel.PluginItem(
                    id: $0.id, title: $0.title, symbolName: $0.symbolName, group: $0.group, order: $0.order,
                    isActive: $0.isActive, needsAttention: $0.needsAttention)
            })
    }
}

/// The Settings mode content: the sidebar and the selected pane.
struct SettingsModeAdapterView: View {
    let entries: [SettingsPaneAdapter.Entry]
    let sections: [SettingsSidebarModel.Section]
    let selection: String
    let onSelect: (String) -> Void
    let onBack: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(sections: sections, selection: selection, onSelect: onSelect, onBack: onBack)
            Divider()
            ScrollView {
                (entries.first { $0.id == selection } ?? entries.first)?.makeView()
                    .frame(maxWidth: .infinity)
                    .id(selection)
            }
        }
    }
}
