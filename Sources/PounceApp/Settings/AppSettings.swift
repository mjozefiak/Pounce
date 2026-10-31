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

    /// The user's order of result sections (plugin ids); empty means `manifest.order`.
    var sectionOrder: [String] {
        didSet { store.setValue(.stringArray(sectionOrder), forKey: SettingsKeys.sectionOrder) }
    }

    init(store: any SettingsStore) {
        self.store = store
        if case .string(let value) = store.value(forKey: SettingsKeys.textSize) {
            textSize = TextSize(setting: value)
        } else {
            textSize = .default
        }
        if case .stringArray(let value) = store.value(forKey: SettingsKeys.sectionOrder) {
            sectionOrder = value
        } else {
            sectionOrder = []
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

    /// Plugin onboarding steps (`OnboardingStep.id`) the user finished or skipped.
    var completedOnboardingSteps: [String] {
        get {
            guard case .stringArray(let value) = store.value(forKey: SettingsKeys.onboardingCompletedSteps) else {
                return []
            }
            return value
        }
        set { store.setValue(.stringArray(newValue), forKey: SettingsKeys.onboardingCompletedSteps) }
    }
}
