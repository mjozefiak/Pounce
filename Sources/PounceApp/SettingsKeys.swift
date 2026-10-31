import Foundation
import PounceKit

/// Every `UserDefaults` key the shell owns, declared in one place. Settings keys are a protected
/// contract (`BACKWARD_COMPATIBILITY.md` section 3): never rename one without a migration.
enum SettingsKeys {
    /// `plugins.<id>.enabled`, a `Bool`; missing means `manifest.defaultEnabled`.
    static func pluginEnabled(_ id: PluginID) -> String {
        "plugins.\(id.rawValue).enabled"
    }
}
