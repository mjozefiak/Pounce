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
        /// `tiling`, `zones` or `free`: how a workspace is arranged unless its override says otherwise.
        static let defaultKind = "defaultKind"
        static let innerGap = "gap.inner"
        static let outerGap = "gap.outer"
        /// Layout ids: the zone layout of a display with no assignment, by the shape of the display (spec Q19).
        static let defaultZoneLayoutLandscape = "defaultZoneLayout.landscape"
        static let defaultZoneLayoutPortrait = "defaultZoneLayout.portrait"
        /// One versioned JSON value with the per-workspace overrides (`WorkspaceOverrides`).
        static let workspaces = "workspaces"
        static let stripEnabled = "strip.enabled"
        static let stripMode = "strip.mode"
        /// Hidden: set by the engine after two launches in a row ended with parked windows; the plugin then
        /// starts switched off with an explanation (spec: Architecture, "Watchdog and safe mode").
        static let safeMode = "safeMode"
        /// Hidden: how many launches in a row ended with parked windows (`safeMode` follows at two).
        static let parkedLaunches = "parkedLaunches"
        /// Hidden: the one-time "Hold ⇧ while dragging to snap" hint was shown.
        static let snapHintShown = "snapHintShown"
        /// Hidden, DEBUG builds only (QA): open the Layouts window when the plugin starts.
        static let qaOpenLayouts = "qaOpenLayouts"
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

    static let defaultInnerGap = 8
    static let defaultOuterGap = 8
    static let maximumGap = 64

    static func clampGap(_ value: Int) -> Int { min(maximumGap, max(0, value)) }

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

    /// Auto-tile unless the user chose otherwise (spec Q5); an unknown stored value reads as Auto-tile.
    var defaultKind: LayoutKind { settings.string(Key.defaultKind).flatMap(LayoutKind.init(rawValue:)) ?? .tiling }

    /// Points between neighbouring windows and around the whole set.
    var innerGap: Int { Self.clampGap(settings.integer(Key.innerGap, default: Self.defaultInnerGap)) }
    var outerGap: Int { Self.clampGap(settings.integer(Key.outerGap, default: Self.defaultOuterGap)) }

    /// The zone layout of a display that has no assignment, by the display's shape: `Columns 2` for landscape and
    /// `Rows 2` for portrait unless the user chose another layout.
    func defaultZoneLayout(for orientation: DisplayOrientation) -> String {
        let key = Self.zoneKey(orientation)
        let stored = settings.string(key) ?? ""
        if !stored.isEmpty { return stored }
        return orientation == .portrait ? StockLayouts.defaultPortrait : StockLayouts.defaultLandscape
    }

    private static func zoneKey(_ orientation: DisplayOrientation) -> String {
        orientation == .portrait ? Key.defaultZoneLayoutPortrait : Key.defaultZoneLayoutLandscape
    }

    /// The per-workspace overrides; a value that is not readable counts as none.
    var workspaceOverrides: WorkspaceOverrides { WorkspaceOverrides(json: settings.string(Key.workspaces)) }

    /// The menu bar strip is on by default while the plugin is on.
    var stripEnabled: Bool { settings.bool(Key.stripEnabled, default: true) }

    var stripMode: StripMode { settings.string(Key.stripMode).flatMap(StripMode.init(rawValue:)) ?? .all }

    var safeMode: Bool { settings.bool(Key.safeMode, default: false) }
    var qaOpenLayouts: Bool { settings.bool(Key.qaOpenLayouts, default: false) }
    var snapHintShown: Bool { settings.bool(Key.snapHintShown, default: false) }
    var parkedLaunches: Int { max(0, settings.integer(Key.parkedLaunches, default: 0)) }

    // MARK: Setters (the pane and the engine write through these)

    func setWorkspaceCount(_ count: Int) {
        settings.set(min(Self.maximumWorkspaces, max(Self.minimumWorkspaces, count)), for: Key.workspaceCount)
    }

    func setDefaultKind(_ kind: LayoutKind) { settings.set(kind.rawValue, for: Key.defaultKind) }
    func setDefaultZoneLayout(_ layoutID: String, for orientation: DisplayOrientation) {
        settings.set(layoutID, for: Self.zoneKey(orientation))
    }

    func setInnerGap(_ points: Int) { settings.set(Self.clampGap(points), for: Key.innerGap) }
    func setOuterGap(_ points: Int) { settings.set(Self.clampGap(points), for: Key.outerGap) }

    /// Stores the overrides unless the stored value is from a newer version (then nothing is written and the
    /// caller learns it). Returns whether it was written.
    @discardableResult
    func setWorkspaceOverrides(_ overrides: WorkspaceOverrides) -> Bool {
        guard !workspaceOverrides.isReadOnly else { return false }
        settings.set(overrides.json, for: Key.workspaces)
        return true
    }

    func setFloatingApps(_ bundleIDs: [String]) { settings.set(bundleIDs, for: Key.floatingApps) }
    func setFollowFocus(_ value: Bool) { settings.set(value, for: Key.followFocus) }
    func setWorkspaceHUD(_ value: Bool) { settings.set(value, for: Key.workspaceHUD) }
    func setStripEnabled(_ value: Bool) { settings.set(value, for: Key.stripEnabled) }
    func setStripMode(_ mode: StripMode) { settings.set(mode.rawValue, for: Key.stripMode) }
    func setSafeMode(_ value: Bool) { settings.set(value, for: Key.safeMode) }
    func setSnapHintShown(_ value: Bool) { settings.set(value, for: Key.snapHintShown) }
    func setParkedLaunches(_ count: Int) { settings.set(max(0, count), for: Key.parkedLaunches) }
}
