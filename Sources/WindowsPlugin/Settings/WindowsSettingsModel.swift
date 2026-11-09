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
    @ObservationIgnored private let settings: WindowsSettings
    @ObservationIgnored private let context: PluginContext
    @ObservationIgnored private let runtime: () -> WindowsRuntime?
    @ObservationIgnored private let preferences: SystemPreferences
    @ObservationIgnored private let translate: ShortcutSafety.KeyTranslation
    @ObservationIgnored private let chooseApp: () -> String?
    @ObservationIgnored var startFailure: () -> WindowsPlugin.StartError? = { nil }

    private(set) var workspaceCount: Int
    private(set) var followFocus: Bool
    private(set) var workspaceHUD: Bool
    private(set) var stripEnabled: Bool
    private(set) var stripMode: WindowsSettings.StripMode
    private(set) var floatingApps: [String]
    /// The current modifiers of the two families; `nil` when the user recorded something else for a command.
    private(set) var goChoice: ModifierChoice?
    private(set) var moveChoice: ModifierChoice?
    /// Shortcuts that type a letter on the active layout.
    private(set) var unsafeShortcuts: [KeyShortcut] = []
    private(set) var status = WindowsStatusInputs()
    private(set) var copiedDiagnostics = false

    init(
        context: PluginContext, settings: WindowsSettings, runtime: @escaping () -> WindowsRuntime?,
        preferences: SystemPreferences = .live,
        translate: @escaping ShortcutSafety.KeyTranslation = {
            SystemKeyTranslation.translate(keyCode: $0, modifiers: $1)
        },
        chooseApp: @escaping () -> String? = { WindowsSettingsModel.chooseAppBundleID() }
    ) {
        self.context = context
        self.settings = settings
        self.runtime = runtime
        self.preferences = preferences
        self.translate = translate
        self.chooseApp = chooseApp
        workspaceCount = settings.workspaceCount
        followFocus = settings.followFocus
        workspaceHUD = settings.workspaceHUD
        stripEnabled = settings.stripEnabled
        stripMode = settings.stripMode
        floatingApps = settings.floatingApps
        goChoice = ModifierChoice(ShortcutFamily.goToWorkspace.defaultModifiers)
        moveChoice = ModifierChoice(ShortcutFamily.moveToWorkspace.defaultModifiers)
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
            stripEnabled: settings.stripEnabled, stripHasRoom: running?.strip?.hasRoom,
            workspaceCount: settings.workspaceCount)
        goChoice = choice(for: ShortcutFamily.goToWorkspace)
        moveChoice = choice(for: ShortcutFamily.moveToWorkspace)
        refreshSafety()
        context.resultsChanged()
    }

    private func choice(for family: ShortcutFamily) -> ModifierChoice? {
        let shortcut = context.commandShortcut(family.commandID(1))
        guard let shortcut else { return nil }
        return ModifierChoice(shortcut.modifiers)
    }

    /// Looks up what each bound key types with its modifiers on the active layout.
    func refreshSafety() {
        let bound = ShortcutFamily.allCases.flatMap { family in
            (1...WindowsSettings.maximumWorkspaces).compactMap { number in
                context.commandShortcut(family.commandID(number))
            }
        }
        unsafeShortcuts = ShortcutSafety.check(bound, translate: translate).offending
    }

    var needsShortcutWarning: Bool { !unsafeShortcuts.isEmpty }

    /// The keys named in the warning, for example "⌥L, ⌥A".
    var unsafeKeyNames: String {
        unsafeShortcuts.map { ((ModifierChoice($0.modifiers)?.symbols) ?? "⌥") + $0.key.uppercased() }.joined(
            separator: ", ")
    }

    // MARK: Writing settings

    private func changed() {
        Task { [weak self] in
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

    func setWorkspaceHUD(_ value: Bool) {
        settings.setWorkspaceHUD(value)
        workspaceHUD = value
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

    /// Sets the modifiers of one family. The two families never share modifiers (they would collide on the same
    /// digit), so the choice the other family holds is refused.
    func setModifiers(_ choice: ModifierChoice, for family: ShortcutFamily) {
        let other = family == .goToWorkspace ? moveChoice : goChoice
        guard choice != other else { return }
        for number in 1...WindowsSettings.maximumWorkspaces {
            context.setCommandShortcut(
                family.commandID(number), KeyShortcut(key: String(number), modifiers: choice.modifiers))
        }
        if family == .goToWorkspace { goChoice = choice } else { moveChoice = choice }
        refreshSafety()
    }

    /// The one-click fix of the warning: ⌃⌥ for the go family and ⌃⌥⇧ for the move family.
    func useControlOption() {
        setModifiers(.controlOption, for: .goToWorkspace)
        setModifiers(.controlOptionShift, for: .moveToWorkspace)
    }

    // MARK: Data

    func restoreAllWindows() async {
        if let runtime = runtime() {
            await runtime.restoreAllWindows()
        } else {
            let report = await WindowsPlugin.restoreFromJournal(context: context)
            WindowsHUDPanel.shared.show(WindowsHUDState(report: report))
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
