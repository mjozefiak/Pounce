import LintelKit
import SwiftUI

extension PluginHost {
    /// The plugins' own Settings panes, in plugin order.
    ///
    /// - Parameter includingInactive: `true` for the main window, which also shows the pane of a disabled or
    ///   failed plugin (dimmed; `settingsPane()` must not open stores or start work, `BACKWARD_COMPATIBILITY.md`
    ///   section 1). The old `SettingsWindowController` passes `false` and shows active plugins only.
    func settingsPanes(includingInactive: Bool) -> [SettingsWindowController.PluginPane] {
        entries.compactMap { entry in
            let isActive = entry.state.isActive
            guard isActive || includingInactive, let view = entry.plugin.settingsPane() else { return nil }
            return SettingsWindowController.PluginPane(
                id: entry.manifest.id.rawValue,
                title: String(localized: entry.manifest.displayName),
                symbolName: entry.manifest.symbolName,
                view: view,
                isActive: isActive,
                group: entry.manifest.settingsGroup,
                order: entry.manifest.order
            )
        }
    }
}
