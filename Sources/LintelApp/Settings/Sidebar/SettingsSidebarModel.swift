import LintelKit

/// The Settings sidebar as data (spec `2026-11-04-lintel-main-window`, step 2.1, decisions D3 and D7). Pure: the
/// grouping and the order come only from the plugins' manifests (`settingsGroup`, `order`), never from plugin ids.
///
/// Groups, in this order: Lintel (General, Features, the plugin panes of the group `.lintel` by `order`,
/// Permissions), Search, Voice, any other plugin group, Models, Advanced.
enum SettingsSidebarModel {
    /// The id of the Models pane (`MainWindowRouter.modelsPaneID`).
    static let modelsID = "models"

    /// What the model needs to know about a plugin's pane.
    struct PluginItem: Equatable {
        let id: String
        let title: String
        let symbolName: String
        let group: SettingsGroup
        let order: Int
        /// False for a disabled or failed plugin: the row is dimmed and says "Off".
        let isActive: Bool
        /// The level of the pane's banner when it is `attention` or `error` (`StatusDerivation.attention`), so the
        /// dot and the banner agree; a failed plugin's error banner gives an error dot on its "Off" row.
        let attention: SettingsStatus.Level?
    }

    struct Item: Equatable, Identifiable {
        let id: String
        let title: String
        let symbolName: String
        let isActive: Bool
        /// `attention` or `error`; `nil` for no dot.
        let attention: SettingsStatus.Level?

        var needsAttention: Bool { attention != nil }

        /// What VoiceOver speaks: the title, "Off" for a dimmed row, "Needs attention" for the dot.
        var accessibilityLabel: String {
            var parts = [title]
            if !isActive {
                parts.append(
                    String(
                        localized: "settings.sidebar.off.spoken", defaultValue: "Off", comment: "Feature state, spoken")
                )
            }
            if needsAttention {
                parts.append(String(localized: "Needs attention", comment: "Settings sidebar item state, spoken"))
            }
            return parts.joined(separator: ", ")
        }
    }

    struct Section: Equatable, Identifiable {
        let id: String
        let title: String
        let items: [Item]
        /// False for Models and Advanced, which the prototype draws without a group label (a gap only); the title
        /// still names the group for VoiceOver.
        var showsTitle = true
    }

    /// - Parameter shellAttention: the dot of a shell pane (Permissions, Models, ...) by pane id, from the banner
    ///   the shell derives for it; only `attention` and `error` give a dot.
    static func sections(
        plugins: [PluginItem], shellAttention: [String: SettingsStatus.Level] = [:]
    ) -> [Section] {
        func shell(_ id: String, _ title: String, _ symbol: String) -> Item {
            let level = shellAttention[id]
            return Item(
                id: id, title: title, symbolName: symbol, isActive: true,
                attention: level == .attention || level == .error ? level : nil)
        }
        func item(_ plugin: PluginItem) -> Item {
            Item(
                id: plugin.id, title: plugin.title, symbolName: plugin.symbolName, isActive: plugin.isActive,
                attention: plugin.attention == .attention || plugin.attention == .error ? plugin.attention : nil)
        }
        func ordered(_ group: SettingsGroup) -> [Item] {
            plugins.filter { $0.group == group }
                .sorted { ($0.order, $0.id) < ($1.order, $1.id) }
                .map(item)
        }

        var result: [Section] = [
            Section(
                id: SettingsGroup.lintel.rawValue, title: String(localized: "Lintel", comment: "Settings group"),
                items: [
                    shell("general", String(localized: "General", comment: "Settings pane title"), "gearshape"),
                    // The prototype's `grid` (the same glyph as Apps).
                    shell("features", String(localized: "Features", comment: "Settings pane title"), "square.grid.2x2"),
                ] + ordered(.lintel) + [
                    shell(
                        "permissions", String(localized: "Permissions", comment: "Settings pane title"), "hand.raised")
                ])
        ]
        let known: Set<SettingsGroup> = [.lintel, .search, .voice]
        func add(_ group: SettingsGroup, title: String) {
            let items = ordered(group)
            if !items.isEmpty { result.append(Section(id: group.rawValue, title: title, items: items)) }
        }
        add(
            .search,
            title: String(localized: "settings.sidebar.search", defaultValue: "Search", comment: "Settings group"))
        add(.voice, title: String(localized: "Voice", comment: "Settings group"))
        // An open set: a group the shell does not know comes after Voice, by its raw value, titled by it.
        let others = Set(plugins.map(\.group)).subtracting(known).sorted { $0.rawValue < $1.rawValue }
        for group in others { add(group, title: group.rawValue.capitalized) }
        result.append(
            Section(
                id: modelsID, title: String(localized: "Models", comment: "Settings group"),
                items: [
                    shell(modelsID, String(localized: "Models", comment: "Settings pane title"), "cube")
                ],
                showsTitle: false
            ))
        result.append(
            Section(
                id: "advanced", title: String(localized: "Advanced", comment: "Settings group"),
                items: [
                    shell(
                        "advanced", String(localized: "Advanced", comment: "Settings pane title"), "slider.horizontal.3"
                    )
                ],
                showsTitle: false
            ))
        return result
    }

    /// The ids in the order the keyboard visits them (top to bottom through every group).
    static func focusOrder(_ sections: [Section]) -> [String] {
        sections.flatMap { $0.items.map(\.id) }
    }
}
