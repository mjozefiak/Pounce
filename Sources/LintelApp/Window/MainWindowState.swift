import Foundation
import LintelKit

/// What the main window shows: a workspace section, or a Settings pane. Stored in `app.mainWindow.mode`,
/// `app.mainWindow.section` and `app.mainWindow.settingsPane` (`BACKWARD_COMPATIBILITY.md` section 3) and restored
/// on the next opening. Pure: the available sections and panes are passed in.
struct MainWindowState: Equatable {
    enum Mode: String, Equatable {
        case workspace
        case settings
    }

    /// The pane Settings falls back to.
    static let defaultSettingsPane = SettingsWindowController.Pane.general.rawValue

    var mode: Mode
    /// The workspace section shown in Workspace mode, and the one Workspace mode returns to; `nil` while no
    /// section is registered.
    var section: String?
    /// The Settings pane shown in Settings mode, and the one Settings mode returns to.
    var settingsPane: String

    /// Restores the stored state against what exists now.
    ///
    /// No registered section means Settings mode. A stored `workspace` mode, a missing mode, or a stored section or
    /// pane id that no longer exists restores to the stored section when it exists, else the first available one,
    /// else to Settings → General. A stored `settings` mode with a known pane reopens that pane.
    ///
    /// - Parameters:
    ///   - sections: the ids of the active plugins' workspace sections, in order.
    ///   - settingsPanes: the ids of the panes Settings mode can show (shell panes and plugin panes).
    static func restore(from store: any SettingsStore, sections: [String], settingsPanes: [String])
        -> MainWindowState
    {
        let storedMode = string(store, SettingsKeys.mainWindowMode).flatMap(Mode.init(rawValue:))
        let storedSection = string(store, SettingsKeys.mainWindowSection)
        let storedPane = string(store, SettingsKeys.mainWindowSettingsPane)

        let paneIsKnown = storedPane.map(settingsPanes.contains) ?? false
        let pane = paneIsKnown ? storedPane ?? defaultSettingsPane : defaultSettingsPane
        let section = storedSection.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first

        if storedMode == .settings, paneIsKnown {
            return MainWindowState(mode: .settings, section: section, settingsPane: pane)
        }
        guard let section else {
            return MainWindowState(mode: .settings, section: nil, settingsPane: pane)
        }
        return MainWindowState(mode: .workspace, section: section, settingsPane: pane)
    }

    /// Writes the state so the next opening restores it.
    func save(to store: any SettingsStore) {
        store.setValue(.string(mode.rawValue), forKey: SettingsKeys.mainWindowMode)
        store.setValue(section.map(SettingValue.string), forKey: SettingsKeys.mainWindowSection)
        store.setValue(.string(settingsPane), forKey: SettingsKeys.mainWindowSettingsPane)
    }

    private static func string(_ store: any SettingsStore, _ key: String) -> String? {
        guard case .string(let value) = store.value(forKey: key), !value.isEmpty else { return nil }
        return value
    }
}
