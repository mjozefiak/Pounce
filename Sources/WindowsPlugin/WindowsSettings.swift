import Foundation
import LintelKit

/// `plugins.windows.*` (a protected contract from the release that ships it, `BACKWARD_COMPATIBILITY.md` §3).
/// Every key is declared here and nowhere else. `plugins.windows.enabled` belongs to the host.
struct WindowsSettings: Sendable {
    enum Key {
        static let workspaceCount = "workspaceCount"
        static let floatingApps = "floatingApps"
        static let followFocus = "followFocus"
        static let showHUD = "showHUD"
        /// `tiling`, `zones` or `free`: how a workspace is arranged unless its override says otherwise.
        static let defaultKind = "defaultKind"
        static let innerGap = "gap.inner"
        static let outerGap = "gap.outer"
        /// Points: how far the windows behind the focused one stick out in an Accordion workspace (0 to 200).
        static let accordionPadding = "accordion.padding"
        /// Points: how much one grow or shrink command moves an Auto-tile edge (5 to 200).
        static let resizeStep = "resize.step"
        /// Hidden: the version of the one-time migration of the default shortcuts (`ShortcutMigration`).
        static let shortcutDefaultsVersion = "shortcutDefaultsVersion"
        /// Layout ids: the zone layout of a display with no assignment, by the shape of the display (spec Q19).
        static let defaultZoneLayoutLandscape = "defaultZoneLayout.landscape"
        static let defaultZoneLayoutPortrait = "defaultZoneLayout.portrait"
        /// One versioned JSON value with the per-workspace overrides (`WorkspaceOverrides`).
        static let workspaces = "workspaces"
        /// One versioned JSON value with the workspace names (`WorkspaceNames`).
        static let workspaceNames = "workspaceNames"
        /// One versioned JSON value with the per-app workspace rules (`AppRules`); float rules stay in `floatingApps`.
        static let appRules = "appRules"
        /// The Layouts window's remembered frame (`NSStringFromRect`), kept here and not in the window system's
        /// own autosave so a QA run never writes to the real defaults domain.
        static let layoutsWindowFrame = "layoutsWindowFrame"
        static let stripEnabled = "strip.enabled"
        static let stripMode = "strip.mode"
        /// Hidden: set by the engine after two launches in a row ended with parked windows; the plugin then
        /// starts switched off with an explanation (spec: Architecture, "Watchdog and safe mode").
        static let safeMode = "safeMode"
        /// Hidden: how many launches in a row ended with parked windows (`safeMode` follows at two).
        static let parkedLaunches = "parkedLaunches"
        /// Hidden: the one-time "Hold ⇧ while dragging to snap" hint was shown.
        static let snapHintShown = "snapHintShown"
        #if DEBUG
        /// Hidden, DEBUG builds only (QA): open the Layouts window when the plugin starts.
        static let qaOpenLayouts = "qaOpenLayouts"
        /// Hidden, DEBUG builds only (QA): the overlay panels can be captured (`ScreenCapture`).
        static let qaCapturable = "qaCapturable"
        /// Hidden, DEBUG builds only (QA): a file the snap-drag timing trace is appended to (`DragTrace`).
        static let qaDragTrace = "qaDragTrace"
        /// Hidden, DEBUG builds only (QA): a file the strip's click details are appended to (`StripTrace`).
        static let qaStripTrace = "qaStripTrace"
        /// Hidden, DEBUG builds only (QA): files and the app picker are scripted, no open or save panel opens.
        static let qaScriptedFiles = "qaScriptedFiles"
        #endif
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
    static let defaultWorkspaceCount = 9
    /// The accordion padding (`plugins.windows.accordion.padding`) and the resize step in points: the defaults and
    /// the ranges `AccordionStrategy` and `TilingStrategy` declare their options with.
    static let defaultAccordionPadding = 30
    static let accordionPaddingRange = 0...200
    static let defaultResizeStep = 50
    static let resizeStepRange = 5...200
    /// The version the migration of the default shortcuts brings the stored shortcuts to.
    static let currentShortcutDefaultsVersion = 1
    /// Never tiled or placed: Lintel itself, System Settings and Calculator (spec Q6). This is the list the release
    /// default has, exactly what `BACKWARD_COMPATIBILITY.md` documents.
    static let documentedFloatingApps = ["com.lintelapp.Lintel", "com.apple.systempreferences", "com.apple.calculator"]
    #if DEBUG
    /// The bundle id of the debug (QA) app (`scripts/make-app.sh`); a release build has no such constant.
    static let qaBundleID = "com.lintelapp.Lintel.QA"
    #endif
    /// The default list: the documented one, and in a DEBUG build also the QA app, so its own windows are never
    /// tiled. The QA id appears in this function only, inside the `#if DEBUG`; a release build has none of it.
    static func makeDefaultFloatingApps() -> [String] {
        var apps = documentedFloatingApps
        #if DEBUG
        apps.insert(Self.qaBundleID, at: 1)
        #endif
        return apps
    }
    static let defaultFloatingApps = makeDefaultFloatingApps()

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
    var showHUD: Bool { settings.bool(Key.showHUD, default: true) }

    /// The kind of a workspace without an override; a value that is not a registered kind (or none) reads as the
    /// registry's default kind.
    func defaultKind(in registry: LayoutRegistry) -> LayoutKind {
        settings.string(Key.defaultKind).map { LayoutKind($0) }.flatMap { registry.contains($0) ? $0 : nil }
            ?? registry.defaultKind
    }

    /// The per-workspace overrides with every kind the registry has no strategy for ignored.
    func workspaceOverrides(in registry: LayoutRegistry) -> WorkspaceOverrides {
        var overrides = workspaceOverrides
        for (workspace, override) in overrides.byWorkspace {
            guard let kind = override.kind, !registry.contains(kind) else { continue }
            var cleaned = override
            cleaned.kind = nil
            overrides.byWorkspace[workspace] = cleaned.isEmpty ? nil : cleaned
        }
        return overrides
    }

    /// The global value of a layout option: its `plugins.windows.<key>` setting made valid, the option's default
    /// when it has no setting or the stored value is not valid.
    func globalValue(of option: LayoutOption) -> JSONValue {
        guard let key = option.settingKey else { return option.defaultValue }
        switch option.domain {
        case .points:
            let stored = settings.integer(key, default: Int.min)
            return stored == Int.min ? option.defaultValue : option.resolved(.int(stored))
        case .choices:
            return option.resolved(settings.string(key).map { JSONValue.string($0) })
        }
    }

    /// Stores the global value of an option that has a setting (made valid first); nothing for one that has none.
    func setGlobalValue(_ value: JSONValue, of option: LayoutOption) {
        guard let key = option.settingKey, let valid = option.valid(value) else { return }
        switch valid {
        case .int(let number): settings.set(number, for: key)
        case .string(let text): settings.set(text, for: key)
        default: break
        }
    }

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

    /// The optional workspace names; a value that is not readable counts as none.
    var workspaceNames: WorkspaceNames { WorkspaceNames(json: settings.string(Key.workspaceNames)) }

    /// Stores the names unless the stored value is from a newer version. Returns whether it was written.
    @discardableResult
    func setWorkspaceNames(_ names: WorkspaceNames) -> Bool {
        guard !workspaceNames.isReadOnly else { return false }
        settings.set(names.json, for: Key.workspaceNames)
        return true
    }

    /// The per-app workspace rules; a value that is not readable counts as none.
    var appRules: AppRules { AppRules(json: settings.string(Key.appRules)) }

    /// Stores the rules unless the stored value is from a newer version. Returns whether it was written.
    @discardableResult
    func setAppRules(_ rules: AppRules) -> Bool {
        guard !appRules.isReadOnly else { return false }
        settings.set(rules.json, for: Key.appRules)
        return true
    }

    var layoutsWindowFrame: String? { settings.string(Key.layoutsWindowFrame) }
    func setLayoutsWindowFrame(_ frame: String) { settings.set(frame, for: Key.layoutsWindowFrame) }

    /// The menu bar strip is on by default while the plugin is on.
    var stripEnabled: Bool { settings.bool(Key.stripEnabled, default: true) }

    var stripMode: StripMode { settings.string(Key.stripMode).flatMap(StripMode.init(rawValue:)) ?? .all }

    var safeMode: Bool { settings.bool(Key.safeMode, default: false) }
    #if DEBUG
    var qaOpenLayouts: Bool { settings.bool(Key.qaOpenLayouts, default: false) }
    var qaCapturable: Bool { settings.bool(Key.qaCapturable, default: false) }
    var qaDragTrace: String? { settings.string(Key.qaDragTrace) }
    var qaStripTrace: String? { settings.string(Key.qaStripTrace) }
    var qaScriptedFiles: Bool { settings.bool(Key.qaScriptedFiles, default: false) }
    #endif
    var shortcutDefaultsVersion: Int { max(0, settings.integer(Key.shortcutDefaultsVersion, default: 0)) }
    func setShortcutDefaultsVersion(_ version: Int) { settings.set(max(0, version), for: Key.shortcutDefaultsVersion) }
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
    func setShowHUD(_ value: Bool) { settings.set(value, for: Key.showHUD) }
    func setStripEnabled(_ value: Bool) { settings.set(value, for: Key.stripEnabled) }
    func setStripMode(_ mode: StripMode) { settings.set(mode.rawValue, for: Key.stripMode) }
    func setSafeMode(_ value: Bool) { settings.set(value, for: Key.safeMode) }
    func setSnapHintShown(_ value: Bool) { settings.set(value, for: Key.snapHintShown) }
    func setParkedLaunches(_ count: Int) { settings.set(max(0, count), for: Key.parkedLaunches) }
}
