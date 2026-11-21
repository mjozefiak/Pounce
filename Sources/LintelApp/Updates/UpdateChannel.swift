import LintelKit

/// The update channels. Stable releases are Sparkle's default channel, which is always offered; a pre-release
/// (`-beta.N`) is published in the channel `beta`.
enum UpdateChannel {
    /// The name in the feed (`sparkle:channel`). Part of the feed contract: never rename it.
    static let beta = "beta"

    /// The channels to offer besides the default one.
    static func allowed(includeBeta: Bool) -> Set<String> {
        includeBeta ? [beta] : []
    }

    /// Whether a `CFBundleShortVersionString` names a pre-release (`0.1.0-beta.2`). Local builds (`0.0.0`) and
    /// stable releases do not.
    static func isPreRelease(version: String) -> Bool {
        version.contains("-beta.")
    }

    /// What `includeBeta(settings:runningVersion:)` would answer, without its write: the stored value, else whether
    /// the running version is a pre-release. For showing the switch before the updater has started.
    static func peekIncludeBeta(settings: any SettingsStore, runningVersion: String) -> Bool {
        if case .bool(let stored)? = settings.value(forKey: SettingsKeys.updatesIncludeBeta) {
            return stored
        }
        return isPreRelease(version: runningVersion)
    }

    /// The value of `app.updates.includeBeta`, written once on the way: the first pre-release build that finds the
    /// key absent stores `true`, so a tester stays on the beta channel; a stable build writes nothing and an absent
    /// key means `false`. A value the user chose is never replaced.
    static func includeBeta(settings: any SettingsStore, runningVersion: String) -> Bool {
        if case .bool(let stored)? = settings.value(forKey: SettingsKeys.updatesIncludeBeta) {
            return stored
        }
        guard isPreRelease(version: runningVersion) else { return false }
        settings.setValue(.bool(true), forKey: SettingsKeys.updatesIncludeBeta)
        return true
    }
}
