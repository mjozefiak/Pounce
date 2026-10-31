import Foundation
import Observation
import PounceKit

/// The clipboard plugin's settings under `plugins.clipboard.` (a protected contract,
/// `BACKWARD_COMPATIBILITY.md` section 3), with change callbacks for the plugin.
@MainActor @Observable
final class ClipboardSettings {
    enum Key {
        /// `Bool`, default `false`: recording is paused (menu bar or settings).
        static let paused = "paused"
        /// `Int`, default 30: entries last used longer ago are deleted.
        static let retentionDays = "retentionDays"
        /// `Int`, default 1000: only this many most recently used entries are kept.
        static let maximumEntries = "maximumEntries"
        /// `[String]` of bundle identifiers; missing means `CaptureFilter.defaultIgnoredApps`.
        static let ignoredApps = "ignoredApps"
        /// `Bool`: the history was reset because its key was missing; cleared when the user dismisses the
        /// notice.
        static let historyResetNotice = "historyResetNotice"
        /// DEBUG builds only, QA mode: `demo` seeds an empty history with fake entries (`docs/qa.md`).
        static let qaSeed = "qaSeed"
    }

    @ObservationIgnored private let store: PluginSettings
    @ObservationIgnored var onChange: (ClipboardSettings) -> Void = { _ in }

    private(set) var isPaused: Bool
    private(set) var retention: RetentionPolicy
    private(set) var ignoredApps: [String]

    init(_ store: PluginSettings) {
        self.store = store
        isPaused = store.bool(Key.paused, default: false)
        retention = RetentionPolicy(
            days: store.integer(Key.retentionDays, default: RetentionPolicy.default.days),
            maximumCount: store.integer(Key.maximumEntries, default: RetentionPolicy.default.maximumCount)
        )
        ignoredApps = store.stringArray(Key.ignoredApps) ?? CaptureFilter.defaultIgnoredApps
    }

    var captureFilter: CaptureFilter {
        CaptureFilter(ignoredApps: Set(ignoredApps))
    }

    var usesDefaultIgnoredApps: Bool {
        Set(ignoredApps) == Set(CaptureFilter.defaultIgnoredApps)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        store.set(paused, for: Key.paused)
        onChange(self)
    }

    func setRetentionDays(_ days: Int) {
        retention.days = max(1, days)
        store.set(retention.days, for: Key.retentionDays)
        onChange(self)
    }

    func setMaximumEntries(_ count: Int) {
        retention.maximumCount = max(1, count)
        store.set(retention.maximumCount, for: Key.maximumEntries)
        onChange(self)
    }

    func addIgnoredApp(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ignoredApps.contains(trimmed) else { return }
        setIgnoredApps(ignoredApps + [trimmed])
    }

    func removeIgnoredApp(_ bundleID: String) {
        setIgnoredApps(ignoredApps.filter { $0 != bundleID })
    }

    func restoreDefaultIgnoredApps() {
        ignoredApps = CaptureFilter.defaultIgnoredApps
        store.removeValue(for: Key.ignoredApps)
        onChange(self)
    }

    private func setIgnoredApps(_ apps: [String]) {
        ignoredApps = apps
        store.set(apps, for: Key.ignoredApps)
        onChange(self)
    }

    var historyResetNotice: Bool {
        get { store.bool(Key.historyResetNotice, default: false) }
        set { store.set(newValue, for: Key.historyResetNotice) }
    }

    var qaSeed: String? {
        store.string(Key.qaSeed)
    }

    /// Names of the default ignored apps, for display; any other entry shows its bundle identifier.
    static let knownAppNames: [String: String] = [
        "com.apple.Passwords": "Passwords",
        "com.apple.keychainaccess": "Keychain Access",
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password 7",
        "com.agilebits.onepassword-osx": "1Password 6",
        "com.bitwarden.desktop": "Bitwarden",
    ]
}
