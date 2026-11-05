import Foundation
import LintelKit

/// The one banner of a Settings pane (spec `2026-11-04-lintel-main-window`, step 2.2), as data. Pure: it gets
/// the host state, the plugin's own `settingsStatus` (read through a closure, so it is never read while the
/// plugin is off or failed) and the permission states, and decides what `StatusBanner` shows.
///
/// Precedence: host state first (off → neutral with Turn On, failed → error with Try Again, both
/// `.enablePlugin`), then the plugin's status combined with the derived permission status. The shown level is
/// the worse of the two in the order `error > attention > ok`; a plugin `neutral` counts as `ok` there.
enum StatusDerivation {
    /// What the shell knows about the pane's plugin.
    enum HostState: Equatable {
        case active
        /// Turning on or off right now: no banner, and the plugin's status is not read.
        case changing
        case off
        case failed
    }

    struct Banner {
        let level: SettingsStatus.Level
        let title: String
        let detail: String?
        /// At most two; the first one is the primary button.
        let actions: [SettingsStatusAction]

        /// What VoiceOver speaks for the banner as one unit: the level, the title and the detail.
        var accessibilityLabel: String {
            [StatusDerivation.levelName(level), title, detail].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// The most buttons a banner shows.
    static let maximumActions = 2

    /// The banner of a plugin pane; `nil` when there is nothing to say.
    ///
    /// - Parameters:
    ///   - pluginStatus: the plugin's `settingsStatus`, called only while the plugin is active.
    ///   - required: the plugin's `requiredPermissions`.
    ///   - permission: the state of each required permission (`PermissionsReader`).
    static func banner(
        host: HostState,
        pluginStatus: () -> SettingsStatus?,
        required: [Permission],
        permission: (Permission) -> PermissionStatus
    ) -> Banner? {
        switch host {
        case .changing:
            return nil
        case .off:
            return Banner(
                level: .neutral,
                title: String(localized: "This feature is off", comment: "Settings banner: the plugin is turned off"),
                detail: String(localized: "Turn it on to use it.", comment: "Settings banner detail: plugin is off"),
                actions: [
                    SettingsStatusAction(
                        title: LocalizedStringResource("Turn On", comment: "Settings banner button: turns a plugin on"),
                        destination: .enablePlugin)
                ])
        case .failed:
            return Banner(
                level: .error,
                title: String(
                    localized: "This feature couldn't start", comment: "Settings banner: the plugin failed to start"),
                detail: String(
                    localized: "Nothing was deleted.", comment: "Settings banner detail: the plugin failed to start"),
                actions: [
                    SettingsStatusAction(
                        title: LocalizedStringResource(
                            "Try Again", comment: "Button that retries opening the clipboard history"),
                        destination: .enablePlugin)
                ])
        case .active:
            return combine(pluginStatus(), required: required, permission: permission)
        }
    }

    private static func combine(
        _ status: SettingsStatus?, required: [Permission], permission: (Permission) -> PermissionStatus
    ) -> Banner? {
        let acknowledged = status?.acknowledgedPermissions ?? []
        var denied: [Permission] = []
        var unreadable: [Permission] = []
        for item in required {
            if !item.isReadable {
                unreadable.append(item)
            } else if permission(item) == .denied, !acknowledged.contains(item) {
                denied.append(item)
            }
            // `.notDetermined` gives no banner from derivation: macOS does not list the app yet.
        }
        let offered = Set(
            (status?.fix ?? []).compactMap { action -> Permission? in
                if case .systemSettings(let permission) = action.destination { return permission }
                return nil
            })
        let fixes = denied.filter { !offered.contains($0) }.map {
            SettingsStatusAction(
                title: LocalizedStringResource(
                    "Open System Settings", comment: "Settings banner button: opens a permission's page"),
                destination: .systemSettings($0))
        }

        guard let status else {
            if !denied.isEmpty {
                return Banner(
                    level: .attention, title: deniedTitle(denied), detail: deniedDetail,
                    actions: Array(fixes.prefix(1)))
            }
            if let first = unreadable.first {
                return Banner(
                    level: .neutral,
                    title: String(
                        localized: "\(first.title) can't be checked",
                        comment: "Settings banner: a permission whose state macOS does not report; the permission name"),
                    detail: String(
                        localized: "macOS doesn't report this permission. Lintel finds out when it's first used.",
                        comment: "Settings banner detail: a permission whose state cannot be read"),
                    actions: [])
            }
            return nil
        }

        let title = String(localized: status.title)
        let detail = status.detail.map { String(localized: $0) }
        guard !denied.isEmpty else {
            return Banner(
                level: status.level, title: title, detail: detail, actions: Array(status.fix.prefix(maximumActions)))
        }
        if rank(status.level) >= rank(.attention) {
            // The plugin's attention or error stays the headline; the permission goes into the detail.
            let permissionLine = "\(deniedTitle(denied)). \(deniedDetail)"
            return Banner(
                level: status.level, title: title,
                detail: detail.map { "\($0) \(permissionLine)" } ?? permissionLine,
                actions: Array((status.fix + fixes.prefix(1)).prefix(maximumActions)))
        }
        // The plugin says ok (or neutral), but a permission it needs is denied: the worse level wins.
        return Banner(
            level: .attention, title: deniedTitle(denied), detail: deniedDetail,
            actions: Array((fixes.prefix(1) + status.fix).prefix(maximumActions)))
    }

    /// The comparison order `error > attention > ok`; a plugin `neutral` counts as `ok`.
    static func rank(_ level: SettingsStatus.Level) -> Int {
        switch level {
        case .ok, .neutral: 0
        case .attention: 1
        case .error: 2
        }
    }

    static func levelName(_ level: SettingsStatus.Level) -> String {
        switch level {
        case .ok: String(localized: "Ready", comment: "Settings banner level, spoken")
        case .attention: String(localized: "Needs attention", comment: "Settings sidebar item state, spoken")
        case .error: String(localized: "Error", comment: "Settings banner level, spoken")
        case .neutral: String(localized: "Information", comment: "Settings banner level, spoken")
        }
    }

    private static func deniedTitle(_ denied: [Permission]) -> String {
        if denied.count == 1, let only = denied.first {
            return String(
                localized: "\(only.title): not allowed",
                comment: "Settings banner: a required permission is denied; the permission name")
        }
        return String(
            localized: "Some permissions aren't allowed", comment: "Settings banner: several permissions are denied")
    }

    private static var deniedDetail: String {
        String(
            localized: "Allow it in System Settings.", comment: "Settings banner detail: a permission is denied")
    }
}
