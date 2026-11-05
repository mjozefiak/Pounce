import SwiftUI

/// Temporary adapter (spec `2026-11-04-lintel-main-window`, step 1.3): lists the panes of the old Settings window
/// (General, Features, the plugins' panes, Permissions, Advanced) and shows the selected one unchanged inside the
/// main window's Settings mode. The sidebar and the pane template replace it in Phase 2 (steps 2.1 to 2.3).
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

    /// The entries in the order of the old window: General, Features, plugin panes, Permissions, Advanced.
    static func entries(
        shellPane: @escaping (SettingsWindowController.Pane) -> AnyView,
        plugins: [SettingsWindowController.PluginPane]
    ) -> [Entry] {
        func shell(_ pane: SettingsWindowController.Pane, _ title: String, _ symbol: String) -> Entry {
            Entry(id: pane.rawValue, title: title, symbolName: symbol, isActive: true) { shellPane(pane) }
        }
        let general = shell(.general, String(localized: "General", comment: "Settings pane title"), "gearshape")
        let features = shell(
            .features, String(localized: "Features", comment: "Settings pane title"), "puzzlepiece.extension")
        let permissions = shell(
            .permissions, String(localized: "Permissions", comment: "Settings pane title"), "hand.raised")
        let advanced = shell(
            .advanced, String(localized: "Advanced", comment: "Settings pane title"), "gearshape.2")
        let pluginEntries = plugins.map { pane in
            Entry(id: pane.id, title: pane.title, symbolName: pane.symbolName, isActive: pane.isActive) { pane.view }
        }
        return [general, features] + pluginEntries + [permissions, advanced]
    }

    /// The row's spoken label: a dimmed row (a disabled or failed plugin) says it is off, not only by its
    /// opacity.
    static func accessibilityLabel(for entry: Entry) -> String {
        guard !entry.isActive else { return entry.title }
        return "\(entry.title), \(String(localized: "Off", comment: "Feature state"))"
    }
}

/// The Settings mode content: a plain pane list and the selected pane.
struct SettingsModeAdapterView: View {
    let entries: [SettingsPaneAdapter.Entry]
    let selection: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            List(
                entries.map(\.id), id: \.self,
                selection: Binding(get: { selection }, set: { if let id = $0 { onSelect(id) } })
            ) { id in
                if let entry = entries.first(where: { $0.id == id }) {
                    Label(entry.title, systemImage: entry.symbolName)
                        .opacity(entry.isActive ? 1 : 0.5)
                        .tag(entry.id)
                        .accessibilityLabel(Text(verbatim: SettingsPaneAdapter.accessibilityLabel(for: entry)))
                        .accessibilityIdentifier("settings.pane.\(entry.id)")
                }
            }
            // A plain list, not the translucent sidebar material: no glass in Settings.
            .listStyle(.plain)
            .frame(width: 200)
            Divider()
            ScrollView {
                (entries.first { $0.id == selection } ?? entries.first)?.makeView()
                    .frame(maxWidth: .infinity)
                    .id(selection)
            }
        }
    }
}
