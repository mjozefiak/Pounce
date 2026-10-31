import Foundation
import PounceKit

/// Every settings key the shell owns, declared in one place. Settings keys are a protected
/// contract (`BACKWARD_COMPATIBILITY.md` section 3): never rename one without a migration.
enum SettingsKeys {
    /// `plugins.<id>.enabled`, a `Bool`; missing means `manifest.defaultEnabled`.
    static func pluginEnabled(_ id: PluginID) -> String {
        "plugins.\(id.rawValue).enabled"
    }

    /// `Bool`: the user recorded the main shortcut themselves, so Pounce never replaces it with a default
    /// (Q10). The shortcut itself is stored by KeyboardShortcuts under `KeyboardShortcuts_mainHotkey`.
    static let hotkeyUserDefined = "app.hotkey.userDefined"

    /// `[String]`: plugin command ids whose default shortcut was already applied once, so a shortcut the
    /// user cleared is not restored.
    static let commandShortcutDefaultsApplied = "app.hotkey.commandDefaultsApplied"

    /// `Bool`: the first-launch Shortcut step was accepted or skipped.
    static let onboardingShortcutCompleted = "app.onboarding.shortcutCompleted"

    /// `[String]`: ids of plugin onboarding steps (`OnboardingStep.id`) finished or skipped; each is shown
    /// once. Added in Phase 2.
    static let onboardingCompletedSteps = "app.onboarding.completedSteps"

    /// `[String]`: plugin ids in the order their result sections appear (issue #5). Plugins not listed
    /// follow in `manifest.order`. Added in Phase 3.
    static let sectionOrder = "app.sectionOrder"

    /// `String`: `s`, `m` (default), `l` or `xl`, the panel's text size.
    static let textSize = "app.textSize"

    /// `String`: `floating` (default) or `statusBar`, the panel's window level. `statusBar` is the spec's
    /// fallback (spike 1.2) if the panel does not appear over full-screen apps.
    static let panelLevel = "app.panelLevel"
}
