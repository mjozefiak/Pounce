import LintelKit
import SwiftUI

extension PluginHost {
    /// The plugins' own Settings panes, in plugin order, the pane of a disabled or failed plugin included (drawn
    /// dimmed; `settingsPane()` must not open stores or start work, `BACKWARD_COMPATIBILITY.md` section 1).
    func settingsPanes() -> [SettingsPluginPane] {
        entries.compactMap { entry in
            guard let view = entry.plugin.settingsPane() else { return nil }
            return SettingsPluginPane(
                id: entry.manifest.id.rawValue,
                title: String(localized: entry.manifest.displayName),
                symbolName: entry.manifest.symbolName,
                view: view,
                isActive: entry.state.isActive,
                group: entry.manifest.settingsGroup,
                order: entry.manifest.order
            )
        }
    }
}
