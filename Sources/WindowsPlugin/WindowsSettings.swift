import Foundation
import LintelKit

/// `plugins.windows.*` (a protected contract from the release that ships it, `BACKWARD_COMPATIBILITY.md` §3).
/// Every key is declared here and nowhere else. `plugins.windows.enabled` belongs to the host.
struct WindowsSettings: Sendable {
    enum Key {
        static let workspaceCount = "workspaceCount"
        static let floatingApps = "floatingApps"
        static let followFocus = "followFocus"
        static let workspaceHUD = "workspaceHUD"
        static let stripEnabled = "strip.enabled"
        static let stripMode = "strip.mode"
        /// Hidden: set by the engine after two launches in a row ended with parked windows; the plugin then
        /// starts switched off with an explanation (spec: Architecture, "Watchdog and safe mode").
        static let safeMode = "safeMode"
        /// Hidden: how many launches in a row ended with parked windows (`safeMode` follows at two).
        static let parkedLaunches = "parkedLaunches"
    }

    /// What the strip shows.
    enum StripMode: String, Sendable, CaseIterable {
        /// Every configured workspace, so box positions never move.
        case all
        /// Only the workspaces that hold a window (and the current one).
        case occupied
    }

    static let minimumWorkspaces = 1
    /// A fixed upper bound of the design: numbered commands, the strip and the assignment matrix assume it.
    static let maximumWorkspaces = 9
    static let defaultWorkspaceCount = 4
    /// Never tiled or placed: Lintel itself, System Settings and Calculator (spec Q6).
    static let defaultFloatingApps = ["com.lintelapp.Lintel", "com.apple.systempreferences", "com.apple.calculator"]

    private let settings: PluginSettings

    init(_ settings: PluginSettings) {
        self.settings = settings
    }

    /// 1 to 9; a stored value outside the range is clamped, never trusted.
    var workspaceCount: Int {
        min(
            Self.maximumWorkspaces,
            max(Self.minimumWorkspaces, settings.integer(Key.workspaceCount, default: Self.defaultWorkspaceCount)))
    }

    /// Bundle identifiers of apps that are never arranged; the default list when none is stored.
    var floatingApps: [String] { settings.stringArray(Key.floatingApps) ?? Self.defaultFloatingApps }

    /// Switch to the workspace of a window that gets focus from outside (⌘Tab, the Dock).
    var followFocus: Bool { settings.bool(Key.followFocus, default: true) }

    /// A brief on-screen number after a switch.
    var workspaceHUD: Bool { settings.bool(Key.workspaceHUD, default: true) }

    /// The menu bar strip is on by default while the plugin is on.
    var stripEnabled: Bool { settings.bool(Key.stripEnabled, default: true) }

    var stripMode: StripMode { settings.string(Key.stripMode).flatMap(StripMode.init(rawValue:)) ?? .all }

    var safeMode: Bool { settings.bool(Key.safeMode, default: false) }
    var parkedLaunches: Int { max(0, settings.integer(Key.parkedLaunches, default: 0)) }

    // MARK: Setters (the pane and the engine write through these)

    func setWorkspaceCount(_ count: Int) {
        settings.set(min(Self.maximumWorkspaces, max(Self.minimumWorkspaces, count)), for: Key.workspaceCount)
    }

    func setFloatingApps(_ bundleIDs: [String]) { settings.set(bundleIDs, for: Key.floatingApps) }
    func setFollowFocus(_ value: Bool) { settings.set(value, for: Key.followFocus) }
    func setWorkspaceHUD(_ value: Bool) { settings.set(value, for: Key.workspaceHUD) }
    func setStripEnabled(_ value: Bool) { settings.set(value, for: Key.stripEnabled) }
    func setStripMode(_ mode: StripMode) { settings.set(mode.rawValue, for: Key.stripMode) }
    func setSafeMode(_ value: Bool) { settings.set(value, for: Key.safeMode) }
    func setParkedLaunches(_ count: Int) { settings.set(max(0, count), for: Key.parkedLaunches) }
}
