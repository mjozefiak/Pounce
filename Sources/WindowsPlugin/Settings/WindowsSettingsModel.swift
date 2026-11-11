import AppKit
import Foundation
import LintelKit
import Observation

/// The modifiers a family of numbered shortcuts can take in the pane (the digits stay fixed).
enum ModifierChoice: String, CaseIterable, Identifiable {
    case option
    case controlOption
    case optionShift
    case controlOptionShift

    var id: String { rawValue }

    var modifiers: KeyShortcut.Modifiers {
        switch self {
        case .option: [.option]
        case .controlOption: [.control, .option]
        case .optionShift: [.option, .shift]
        case .controlOptionShift: [.control, .option, .shift]
        }
    }

    init?(_ modifiers: KeyShortcut.Modifiers) {
        guard let match = Self.allCases.first(where: { $0.modifiers == modifiers }) else { return nil }
        self = match
    }

    /// "⌥", "⌃⌥", "⌥⇧", "⌃⌥⇧".
    var symbols: String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "")
    }
}

/// The state behind the Window Management pane. Creating it reads settings only; nothing starts until the pane is
/// shown for an active plugin (`refresh()`), so the pane of a plugin that is off does no work (spec: Settings
/// pane rule, `InactiveSettingsPaneTests`).
@MainActor @Observable
final class WindowsSettingsModel {
    /// What the views' buttons start, in the order the user pressed them.
    let actions = OrderedActions()
    @ObservationIgnored let settings: WindowsSettings
    @ObservationIgnored let context: PluginContext
    @ObservationIgnored let runtime: () -> WindowsRuntime?
    @ObservationIgnored private let preferences: SystemPreferences
    @ObservationIgnored private let translate: ShortcutSafety.KeyTranslation
    @ObservationIgnored private let chooseApp: () -> String?
    @ObservationIgnored var startFailure: () -> WindowsPlugin.StartError? = { nil }
    /// Opens the Layouts window (the plugin sets it).
    @ObservationIgnored var openLayouts: () -> Void = {}
    /// Where the restore report is shown when no engine runs; the plugin passes its own presenter, so the pane
    /// and the plugin never use two different ones.
    @ObservationIgnored var hud: any WindowsHUDPresenting = NullHUD()
    /// One pass over the journal when no engine runs; the plugin sets it.
    @ObservationIgnored var restoreFromJournal: () async -> JournalOwner.Pass<RecoveryReport> = {
        .ran(RecoveryReport())
    }

    private(set) var workspaceCount: Int
    private(set) var followFocus: Bool
    private(set) var showHUD: Bool
    private(set) var stripEnabled: Bool
    private(set) var stripMode: WindowsSettings.StripMode
    private(set) var floatingApps: [String]
    /// The user's own layouts and the layout slots, as the library last reported them (`reloadLibrary()`).
    var libraryLayouts: [GridLayout] = []
    var layoutSlots: [Int: String] = [:]
    var libraryLocked = false
    /// The current modifiers of each shortcut family; a family is missing when the user recorded something else
    /// for one of its commands.
    private(set) var choices: [ShortcutFamily: ModifierChoice] = [:]
    var goChoice: ModifierChoice? { choices[.goToWorkspace] }
    var moveChoice: ModifierChoice? { choices[.moveToWorkspace] }

    // The layout settings (`WindowsSettingsModel+Layout.swift` changes them).
    /// The strategies of this build: the kinds the pane offers, their names and summaries.
    let registry: LayoutRegistry
    var defaultKind: LayoutKind
    /// The global value of every option, by option id (the pane's rows of each kind read and write it).
    var globalOptions: [String: JSONValue] = [:]
    var overrides: WorkspaceOverrides
    /// The workspace whose overrides the pane is editing, if any.
    var editingWorkspace: WorkspaceID?
    /// The commands whose shortcut types a letter on the active layout, with that shortcut.
    private(set) var flagged: [(id: String, shortcut: KeyShortcut)] = []
    /// Shortcuts that type a letter on the active layout.
    var unsafeShortcuts: [KeyShortcut] { flagged.map(\.shortcut) }
    /// Families whose commands do not all use the same modifiers (after "Use ⌃⌥ for these" changed some).
    private(set) var mixedFamilies: Set<ShortcutFamily> = []
    private(set) var status = WindowsStatusInputs()
    private(set) var copiedDiagnostics = false
    /// The last modifier choice was refused because the other family holds it.
    private(set) var modifierConflict = false

    init(
        context: PluginContext, settings: WindowsSettings, registry: LayoutRegistry,
        runtime: @escaping () -> WindowsRuntime?,
        preferences: SystemPreferences = .live,
        translate: @escaping ShortcutSafety.KeyTranslation = {
            SystemKeyTranslation.translate(keyCode: $0, modifiers: $1)
        },
        chooseApp: @escaping () -> String? = { WindowsSettingsModel.chooseAppBundleID() }
    ) {
        self.context = context
        self.settings = settings
        self.registry = registry
        self.runtime = runtime
        self.preferences = preferences
        self.translate = translate
        self.chooseApp = chooseApp
        workspaceCount = settings.workspaceCount
        followFocus = settings.followFocus
        showHUD = settings.showHUD
        stripEnabled = settings.stripEnabled
        stripMode = settings.stripMode
        floatingApps = settings.floatingApps
        defaultKind = settings.defaultKind(in: registry)
        overrides = settings.workspaceOverrides
        globalOptions = Self.globalOptions(settings, registry)
        for family in ShortcutFamily.active(in: registry) {
            choices[family] = ModifierChoice(family.defaultModifiers)
        }
    }

    // MARK: Reading the world (only while the plugin is active)

    /// Re-reads what the banner and the shortcut rows depend on. Called when the pane appears for an active
    /// plugin and when Lintel becomes the active app again.
    func refresh() async {
        let running = runtime()
        let trusted = running?.trust.refresh() ?? (context.permissions.status(of: .accessibility) == .granted)
        let parked = await running?.engine.hasParkedWindows() ?? false
        status = WindowsStatusInputs(
            trusted: trusted, hasParkedWindows: parked, engineBanner: running?.engineBanner,
            stageManagerOn: preferences.stageManagerOn, displaysShareASpace: preferences.displaysShareASpace,
            stripEnabled: settings.stripEnabled, stripHasRoom: running?.strip?.refreshRoom(),
            workspaceCount: settings.workspaceCount)
        refreshChoices()
        await reloadLibrary()
        overrides = settings.workspaceOverrides
        globalOptions = Self.globalOptions(settings, registry)
        refreshSafety()
        context.resultsChanged()
    }

    private func refreshChoices() {
        mixedFamilies = []
        for family in ShortcutFamily.active(in: registry) {
            choices[family] = choice(for: family)
            if choices[family] == nil, isMixed(family) { mixedFamilies.insert(family) }
        }
    }

    /// The modifiers every command of the family uses, as a choice; `nil` when they differ or are not a choice.
    private func choice(for family: ShortcutFamily) -> ModifierChoice? {
        let all = Set(family.bindings(in: registry).compactMap { context.commandShortcut($0.id)?.modifiers })
        guard all.count == 1, let only = all.first else { return nil }
        return ModifierChoice(only)
    }

    private func isMixed(_ family: ShortcutFamily) -> Bool {
        Set(family.bindings(in: registry).compactMap { context.commandShortcut($0.id)?.modifiers }).count > 1
    }

    /// The commands with a shortcut of their own that the check covers: the families, Toggle Layout and Back.
    private var boundCommandIDs: [String] {
        ShortcutFamily.active(in: registry).flatMap { $0.bindings(in: registry).map(\.id) }
            + [WindowsCommandID.toggleLayout, WindowsCommandID.back]
    }

    /// Looks up what each bound key types with its modifiers on the active layout, and tells the banner.
    func refreshSafety() {
        let bound = boundCommandIDs.compactMap { id in context.commandShortcut(id).map { (id: id, shortcut: $0) } }
        let offending = ShortcutSafety.check(bound.map(\.shortcut), translate: translate).offending
        flagged = bound.filter { offending.contains($0.shortcut) }
        status.unsafeShortcuts = unsafeShortcuts
    }

    var needsShortcutWarning: Bool { !flagged.isEmpty }

    /// The keys named in the warning, for example "⌥L, ⌥A".
    var unsafeKeyNames: String { ShortcutWarning.names(unsafeShortcuts) }

    // MARK: Writing settings

    private func changed() {
        actions.enqueue { [weak self] in
            await self?.runtime()?.applySettings()
            self?.context.resultsChanged()
        }
    }

    func setWorkspaceCount(_ count: Int) {
        settings.setWorkspaceCount(count)
        workspaceCount = settings.workspaceCount
        status.workspaceCount = workspaceCount
        changed()
    }

    func setFollowFocus(_ value: Bool) {
        settings.setFollowFocus(value)
        followFocus = value
        changed()
    }

    func setShowHUD(_ value: Bool) {
        settings.setShowHUD(value)
        showHUD = value
    }

    func setStripEnabled(_ value: Bool) {
        settings.setStripEnabled(value)
        stripEnabled = value
        status.stripEnabled = value
        changed()
    }

    func setStripMode(_ mode: WindowsSettings.StripMode) {
        settings.setStripMode(mode)
        stripMode = mode
        changed()
    }

    func removeFloatingApp(_ bundleID: String) {
        floatingApps.removeAll { $0 == bundleID }
        settings.setFloatingApps(floatingApps)
        changed()
    }

    func addFloatingApp() {
        guard let bundleID = chooseApp(), !floatingApps.contains(bundleID) else { return }
        floatingApps.append(bundleID)
        settings.setFloatingApps(floatingApps)
        changed()
    }

    func resetFloatingApps() {
        floatingApps = WindowsSettings.defaultFloatingApps
        settings.setFloatingApps(floatingApps)
        changed()
    }

    /// The choice the partner family (the one bound to the same keys) holds.
    func partnerChoice(of family: ShortcutFamily) -> ModifierChoice? {
        family.partner.flatMap { choices[$0] }
    }

    /// Sets the modifiers of one family. Two families on the same keys never share modifiers (they would
    /// collide), so the choice the partner holds is refused.
    func setModifiers(_ choice: ModifierChoice, for family: ShortcutFamily) {
        let other = partnerChoice(of: family)
        modifierConflict = choice == other
        guard choice != other else { return }
        for binding in family.bindings(in: registry) {
            context.setCommandShortcut(binding.id, KeyShortcut(key: binding.key, modifiers: choice.modifiers))
        }
        choices[family] = choice
        mixedFamilies.remove(family)
        refreshSafety()
    }

    /// The one-click fix of the warning: ⌃ is added to the shortcuts that type a character, and only to those, so
    /// the rest of a family keeps its modifiers (its row then says "Mixed"). Undone with the family's modifier row.
    func useControlOption() {
        for item in flagged {
            context.setCommandShortcut(item.id, ShortcutSafety.controlOption(for: [item.shortcut])[0])
        }
        refreshChoices()
        refreshSafety()
    }

    // MARK: Data

    func restoreAllWindows() async {
        if let runtime = runtime() {
            await runtime.restoreAllWindows()
        } else {
            switch await restoreFromJournal() {
            case .ran(let report): hud.show(WindowsHUDState(report: report))
            case .engineRunning, .engineStopping, .cancelled: hud.show(.stillStopping)
            }
        }
        await refresh()
    }

    func resetState() async {
        await runtime()?.resetState()
        await refresh()
    }

    func copyDiagnostics() async {
        guard let text = await runtime()?.diagnosticsText() else { return }
        context.pasteboard.setString(text)
        copiedDiagnostics = true
    }

    // MARK: The banner's own actions

    func perform(_ actionID: String) async {
        switch actionID {
        case WindowsStatusAction.restoreWindows: await restoreAllWindows()
        case WindowsStatusAction.startAgain: await runtime()?.startAgain()
        case WindowsStatusAction.useControlOption: useControlOption()
        case WindowsStatusAction.openStageManager:
            open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
        case WindowsStatusAction.openSpaces: open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
        default: break
        }
        await refresh()
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        let workspace = context.workspace
        Task { try? await workspace.open(url) }
    }

    /// What the floating list shows for a bundle id: the app's name when it is installed, else the id itself.
    func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// "Add App…": the bundle id of the chosen app.
    static func chooseAppBundleID() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.prompt = String(localized: "Add", comment: "Button of the app picker for floating apps")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
