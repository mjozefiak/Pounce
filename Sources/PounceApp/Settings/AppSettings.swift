import Foundation
import Observation
import PounceKit

/// The shell's own settings (`app.*`) that views bind to.
@Observable
final class AppSettings {
    @ObservationIgnored private let store: any SettingsStore

    var textSize: TextSize {
        didSet { store.setValue(.string(textSize.rawValue), forKey: SettingsKeys.textSize) }
    }

    init(store: any SettingsStore) {
        self.store = store
        if case .string(let value) = store.value(forKey: SettingsKeys.textSize) {
            textSize = TextSize(setting: value)
        } else {
            textSize = .default
        }
    }

    var panelLevel: LauncherPanel.Level {
        guard case .string(let value) = store.value(forKey: SettingsKeys.panelLevel) else { return .floating }
        return LauncherPanel.Level(rawValue: value) ?? .floating
    }

    var shortcutOnboardingCompleted: Bool {
        get {
            guard case .bool(let value) = store.value(forKey: SettingsKeys.onboardingShortcutCompleted) else {
                return false
            }
            return value
        }
        set { store.setValue(.bool(newValue), forKey: SettingsKeys.onboardingShortcutCompleted) }
    }
}
