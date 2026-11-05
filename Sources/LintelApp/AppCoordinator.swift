import AppKit
import LintelKit
import LintelUI
import SwiftUI
import os

/// Composition root: builds the environment, the plugin host and the window controllers, and owns
/// them for the lifetime of the app.
final class AppCoordinator {
    let environment: AppEnvironment
    let host: PluginHost
    let appSettings: AppSettings
    let hotkeys: HotkeyService
    let panelModel: PanelModel
    let launchAtLogin: any LaunchAtLoginClient
    private(set) var statusItem: StatusItemController?
    private(set) var panel: PanelController?
    private(set) var settingsWindow: SettingsWindowController?
    /// The shell panes' views, shared by the old Settings window and the main window's Settings mode.
    private var shellPane: ((SettingsWindowController.Pane) -> AnyView)?
    private(set) var onboarding: OnboardingController?
    private(set) var about: AboutWindowController?
    #if DEBUG
    /// The main window, behind the release gate of ADR 0008 until step 6.3: built on first use, DEBUG only.
    private(set) var mainWindow: MainWindowController?
    private var mainMenu: MainMenuController?
    /// The one banner of the main window's Settings mode (spec step 2.2); built with the Settings mode.
    private var settingsHost: SettingsHostModel?
    #endif
    /// Shows the welcome screen's pending steps. Set in `start()` outside QA mode; tests replace it.
    var presentPendingOnboarding: (@MainActor () -> Void)?
    private let search: SearchCoordinator
    private let settingsRelay: PluginSettingsRelay
    /// `PluginContext.resultsChanged` with the plugin's id, for the Settings banner.
    private let statusRelay = PluginStatusRelay()
    private let icons: IconCache
    private let logger = Logger(subsystem: "com.lintelapp", category: "app")

    /// - Parameters:
    ///   - registrar: where global shortcuts go; QA mode passes one that registers nothing.
    ///   - occupiedShortcuts: the shortcuts the system holds (symbolic hotkeys 64 and 65).
    init(
        environment: AppEnvironment,
        pluginTypes: [any LintelPlugin.Type] = PluginRegistry.all,
        registrar: any HotkeyRegistrar,
        occupiedShortcuts: @escaping () -> Set<HotkeyShortcut>,
        launchAtLogin: any LaunchAtLoginClient
    ) {
        self.environment = environment
        let relay = ResultsChangedRelay()
        let settingsRelay = PluginSettingsRelay()
        self.settingsRelay = settingsRelay
        let statusRelay = statusRelay
        let hotkeys = HotkeyService(
            registrar: registrar,
            settings: environment.settings,
            readOccupied: occupiedShortcuts,
            allowsRecording: environment.registersGlobalHotkeys
        )
        self.hotkeys = hotkeys
        self.host = PluginHost(
            pluginTypes: pluginTypes,
            makeContext: { manifest in
                environment.makeContext(
                    for: manifest,
                    resultsChanged: {
                        Task { @MainActor in
                            relay.signal()
                            statusRelay.signal(manifest.id.rawValue)
                        }
                    },
                    makeShortcutRecorder: { commandID in
                        AnyView(CommandShortcutRecorder(hotkeys: hotkeys, commandID: commandID))
                    },
                    claimEscapeKey: { onEscape in hotkeys.claimEscape(onEscape) },
                    openSettings: { settingsRelay.open(manifest.id.rawValue) },
                    openModels: { packageID in settingsRelay.openModels(manifest.id.rawValue, packageID) }
                )
            },
            settings: environment.settings
        )
        let appSettings = AppSettings(store: environment.settings)
        self.appSettings = appSettings
        self.launchAtLogin = launchAtLogin
        let search = SearchCoordinator(
            host: host, usage: environment.usage, sectionOrder: { appSettings.sectionOrder })
        self.search = search
        let panelModel = PanelModel { query in await search.search(query) }
        self.panelModel = panelModel
        relay.handler = { [weak panelModel] in panelModel?.resultsChanged() }
        self.icons = IconCache(
            diskDirectory: environment.cachesRoot.appending(path: "icons", directoryHint: .isDirectory))
        settingsRelay.handler = { [weak self] id in self?.openPluginSettings(id) }
        settingsRelay.modelsHandler = { [weak self] id, packageID in self?.openModels(from: id, packageID: packageID) }
        #if DEBUG
        statusRelay.handler = { [weak self] id in self?.settingsHost?.pluginResultsChanged(id) }
        #endif
    }

    /// Builds the panel and windows, activates the enabled plugins, registers shortcuts and, while steps
    /// are pending, shows the welcome screen.
    func start() async {
        let host = host
        statusItem = StatusItemController(
            actions: ShellMenuActions(
                openPanel: { [weak self] in self?.panelModel.show() },
                openSettings: { [weak self] in self?.openSettingsFromMenu() },
                mainShortcut: { [weak self] in self?.hotkeys.mainShortcut },
                runCommand: { [weak self] command in self?.perform(command) },
                commandShortcut: { [weak self] id in self?.hotkeys.commandShortcut(id) },
                showAbout: { [weak self] in self?.showAbout() }
            )
        ) { host.activeCommands }

        buildPanel()
        buildWindows()

        DockPresence.apply(showInDock: appSettings.showInDock)
        appSettings.showInDockChanged = { [weak self] showInDock in
            DockPresence.apply(showInDock: showInDock)
            if !showInDock { self?.settingsWindow?.bringToFrontIfVisible() }
            #if DEBUG
            // Changing the activation policy can drop the main menu; put it back for the key window.
            self?.mainMenu?.refresh()
            #endif
        }

        await host.start()
        hotkeys.start { [weak self] in self?.panelModel.toggle() }
        syncCommands()
        statusItem?.rebuildMenu()
        logger.info("Started with \(host.entries.count, privacy: .public) plugins")

        if environment.registersGlobalHotkeys {
            presentPendingOnboarding = { [weak self] in self?.onboarding?.showPendingSteps() }
            presentPendingOnboarding?()
        }
    }

    /// Sends the Dock, Command-comma, "Settings…", `openModels` and `openNote` to the main window while it is
    /// enabled (DEBUG until step 6.3a), else to the old Settings window as before (ADR 0008, "Release gate").
    private(set) lazy var router = makeRouter()

    /// A click on the Dock icon (or opening the app again from Finder): the main window while it is enabled,
    /// else Settings, unless a window is already open.
    func reopen(appKitHasVisibleWindows: Bool) {
        router.reopen(appKitHasVisibleWindows: appKitHasVisibleWindows, visibleWindowRoles: visibleWindowRoles())
    }

    /// Command-comma in the launcher panel and the status item's "Settings…".
    func openSettingsFromMenu() {
        router.openSettings()
    }

    /// `PluginContext.openModels` of the plugin `pluginID`.
    func openModels(from pluginID: String, packageID: String?) {
        router.openModels(from: pluginID, packageID: packageID)
    }

    /// An `openNote` route (kind `openNote`, `WorkspaceSection.handleRoute`): `true` only when a section of the
    /// enabled main window handled it; the caller keeps its old behaviour otherwise.
    @discardableResult
    func openNote(_ route: WorkspaceRoute) -> Bool {
        router.open(route)
    }

    /// The active plugins' workspace sections, by `order`.
    private static func activeWorkspaceSections(_ host: PluginHost) -> [WorkspaceSection] {
        host.entries.filter(\.state.isActive).flatMap(\.plugin.workspaceSections).sorted { $0.order < $1.order }
    }

    private func visibleWindowRoles() -> [KeyWindowRole] {
        #if DEBUG
        let main = mainWindow?.window
        #else
        let main: NSWindow? = nil
        #endif
        return DockPresence.appWindowRoles(NSApp.windows.filter(\.isVisible), mainWindow: main)
    }

    private func makeRouter() -> MainWindowRouter {
        let host = host
        var targets = MainWindowRouter.Targets()
        targets.showLegacySettings = { [weak self] pane in self?.openSettings(pane) }
        targets.showLegacyPluginPane = { [weak self] id in self?.openPluginSettings(id) }
        targets.modelUsers = {
            host.entries.filter(\.state.isActive).map {
                MainWindowRouter.ModelUser(
                    pluginID: $0.manifest.id.rawValue, packageIDs: $0.plugin.modelUsage.map(\.packageID))
            }
        }
        targets.sections = { Self.activeWorkspaceSections(host) }
        #if DEBUG
        targets.showMainWindow = { [weak self] in self?.showMainWindow { $0.show() } }
        targets.showMainWindowSettings = { [weak self] pane in self?.showMainWindow { $0.showSettings(pane) } }
        targets.showMainWindowSection = { [weak self] id in self?.showMainWindow { $0.showWorkspace(id) } }
        #endif
        return MainWindowRouter(targets: targets)
    }

    /// Deactivates every plugin before the app exits.
    func stop() async {
        #if DEBUG
        // The visible workspace section flushes what it holds before the plugins stop.
        await mainWindow?.prepareForTermination()
        #endif
        await host.stop()
    }

    /// Hides the panel first, refreshes the default shortcut (Spotlight may have released ⌘Space), and
    /// shows Settings.
    func openSettings(_ pane: SettingsWindowController.Pane = .general) {
        panelModel.hide()
        hotkeys.refreshDefault()
        settingsWindow?.show(pane)
    }

    /// The plugin panes of the main window's Settings mode: unlike the old Settings window, it includes disabled
    /// and failed plugins, drawn dimmed. Used by the main window (spec steps 1.2 and 1.3), which stays behind the
    /// DEBUG release gate until step 6.3.
    func mainWindowPluginPanes() -> [SettingsWindowController.PluginPane] {
        host.settingsPanes(includingInactive: true)
    }

    /// Hides the panel first and shows the About window with the third-party notices.
    func showAbout() {
        panelModel.hide()
        about?.show()
    }

    /// Shows a plugin's own Settings pane.
    func openPluginSettings(_ id: String) {
        panelModel.hide()
        hotkeys.refreshDefault()
        settingsWindow?.showPluginPane(id)
    }

    /// A plugin command from its shortcut or the menu: open its panel mode, or run it.
    func perform(_ command: PluginCommand) {
        if let mode = command.panelMode {
            let target = PanelModel.Mode.plugin(mode)
            if panelModel.isVisible, panelModel.mode == target {
                panelModel.hide()
            } else {
                panelModel.show(mode: target)
            }
            return
        }
        let run = command.run
        Task { await run() }
    }

    /// A phase of a command's shortcut, delivered synchronously from the key event stream. Before the
    /// key-down the launcher panel is hidden, so the plugin's Command-V does not land in its search field.
    func deliver(_ command: PluginCommand, phase: KeyPhase) {
        if phase == .down {
            panelModel.hide()
        }
        command.onKeyEvent?(phase)
    }

    private func syncCommands() {
        hotkeys.syncCommands(
            host.activeCommands,
            perform: { [weak self] command in self?.perform(command) },
            deliver: { [weak self] command, phase in self?.deliver(command, phase: phase) })
    }

    private func buildPanel() {
        panelModel.textSize = appSettings.textSize
        // Plugin windows (the meeting window) read the app's text size through LintelUI.
        let appSettings = appSettings
        AppTextSize.current = { appSettings.textSize }
        panelModel.previousApplication = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        panelModel.openSettings = { [weak self] in self?.openSettings(.features) }
        panelModel.openPluginSettings = { [weak self] id in self?.openPluginSettings(id.rawValue) }
        let host = host
        panelModel.panelMode = { id in host.activePanelModes.first { $0.id == id } }
        let search = search
        panelModel.modeSearch = { mode, text, filter in await search.search(mode: mode, raw: text, filter: filter) }
        let controller = PanelController(model: panelModel, icons: icons, level: appSettings.panelLevel)
        controller.takesKeyFocus = environment.registersGlobalHotkeys
        controller.onOpenSettings = { [weak self] in self?.openSettingsFromMenu() }
        panel = controller
        observeTextSize()
    }

    private func buildWindows() {
        let hotkeys = hotkeys
        let settings = appSettings
        let launchAtLogin = launchAtLogin
        let host = host
        let shell: (SettingsWindowController.Pane) -> AnyView = { [environment, weak self] pane in
            switch pane {
            case .general:
                return AnyView(GeneralPane(hotkeys: hotkeys, settings: settings, launchAtLogin: launchAtLogin))
            case .features:
                return AnyView(FeaturesPane(host: host, settings: settings) { self?.pluginsChanged() })
            case .permissions:
                let model = PermissionsModel(host: host, reader: environment.permissionsReader) { url in
                    NSWorkspace.shared.open(url)
                }
                return AnyView(PermissionsPane(model: model))
            case .advanced:
                return AnyView(
                    AdvancedPane(
                        controls: AdvancedControls(usage: environment.usage) { self?.panelModel.resultsChanged() }))
            }
        }
        shellPane = shell
        let window = SettingsWindowController(
            general: { shell(.general) },
            features: { shell(.features) },
            permissions: { shell(.permissions) },
            advanced: { shell(.advanced) },
            // The old window keeps skipping inactive plugins until it is removed (spec step 6.3).
            pluginPanes: { host.settingsPanes(includingInactive: false) }
        )
        window.activatesApp = environment.registersGlobalHotkeys
        window.textSize = { settings.textSize }
        settingsWindow = window

        let onboarding = OnboardingController(hotkeys: hotkeys, settings: settings) {
            host.entries.filter(\.state.isActive).flatMap(\.plugin.onboardingSteps)
        }
        onboarding.activatesApp = environment.registersGlobalHotkeys
        self.onboarding = onboarding

        let about = AboutWindowController()
        about.activatesApp = environment.registersGlobalHotkeys
        self.about = about
    }

    /// A plugin was turned on or off or erased: shortcuts and the menu follow, and a plugin that was just
    /// enabled shows its pending onboarding steps now instead of at the next launch.
    func pluginsChanged() {
        syncCommands()
        statusItem?.rebuildMenu()
        presentPendingOnboarding?()
    }

    private func observeTextSize() {
        withObservationTracking {
            _ = appSettings.textSize
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panelModel.textSize = self.appSettings.textSize
                self.observeTextSize()
            }
        }
    }

    #if DEBUG
    /// QA (`--qa-window`): opens the main window in a mode.
    func showMainWindowForQA(_ mode: MainWindowState.Mode, settingsPane: String? = nil) {
        showMainWindow { window in
            switch mode {
            case .workspace: window.showWorkspace()
            case .settings: window.showSettings(settingsPane)
            }
        }
    }

    /// Builds the main window on first use and shows it through `present`.
    private func showMainWindow(_ present: (MainWindowController) -> Void) {
        panelModel.hide()
        hotkeys.refreshDefault()
        present(mainWindow ?? makeMainWindow())
    }

    /// Settings mode: the sidebar, the one banner (`SettingsHost`) and the old window's panes through the
    /// temporary adapter (spec step 1.3).
    private func settingsModeContent(_ state: MainWindowState) -> AnyView {
        guard let shellPane else { return AnyView(EmptyView()) }
        let panes = mainWindowPluginPanes()
        let entries = SettingsPaneAdapter.entries(shellPane: shellPane, plugins: panes)
        let hasSection = state.section != nil
        return AnyView(
            SettingsHost(
                model: settingsHost ?? makeSettingsHost(),
                entries: entries, sections: SettingsPaneAdapter.sidebarSections(plugins: panes),
                selection: state.settingsPane,
                onSelect: { [weak self] id in self?.mainWindow?.selectSettingsPane(id) },
                onBack: hasSection ? { [weak self] in self?.mainWindow?.showWorkspace() } : nil))
    }

    private func makeSettingsHost() -> SettingsHostModel {
        var navigation = SettingsHostModel.Navigation()
        navigation.openModels = { [weak self] id, packageID in self?.openModels(from: id, packageID: packageID) }
        navigation.openURL = { url in NSWorkspace.shared.open(url) }
        navigation.pluginsChanged = { [weak self] in self?.pluginsChanged() }
        let model = SettingsHostModel(host: host, reader: environment.permissionsReader, navigation: navigation)
        settingsHost = model
        return model
    }

    private func makeMainWindow() -> MainWindowController {
        let host = host
        let window = MainWindowController(
            settings: environment.settings,
            sections: { Self.activeWorkspaceSections(host) },
            settingsPanes: { [weak self] in
                SettingsWindowController.Pane.allCases.map(\.rawValue) + [MainWindowRouter.modelsPaneID]
                    + (self?.mainWindowPluginPanes().map(\.id) ?? [])
            },
            // QA mode never writes the frame into the tester's defaults.
            frameAutosaveName: environment.registersGlobalHotkeys ? MainWindowController.autosaveName : nil,
            makeContent: { [weak self] state, sections in
                if state.mode == .settings {
                    return self?.settingsModeContent(state) ?? AnyView(EmptyView())
                }
                guard let section = sections.first(where: { $0.id == state.section })
                else { return AnyView(EmptyView()) }
                return section.makeView()
            }
        )
        window.activatesApp = environment.registersGlobalHotkeys
        let appSettings = appSettings
        window.textSize = { appSettings.textSize }
        mainWindow = window
        // QA mode (no global hotkeys) never installs a menu into the tester's session either.
        if environment.registersGlobalHotkeys {
            let menu = MainMenuController(
                mainWindow: { [weak window] in window?.window },
                mode: { [weak window] in window?.state?.mode },
                section: { [weak window] in window?.activeSection },
                openSettings: { [weak self] in self?.openSettingsFromMenu() })
            window.onChange = { [weak menu] in menu?.refresh() }
            menu.start()
            mainMenu = menu
        }
        return window
    }

    /// QA: shows the whole welcome screen regardless of what was completed.
    func showOnboardingForQA() {
        onboarding?.showAllSteps()
    }

    /// QA: shows the whole welcome screen on one page: `intro`, `shortcut` or a plugin step id.
    func showOnboardingStepForQA(_ id: String) {
        let steps = host.entries.filter(\.state.isActive).flatMap(\.plugin.onboardingSteps)
        guard [WelcomePage.introID, WelcomePage.shortcutID].contains(id) || steps.contains(where: { $0.id == id })
        else {
            logger.error("No active onboarding step \(id, privacy: .public)")
            return
        }
        onboarding?.showAllSteps(startingAt: id)
    }
    #endif
}

/// Forwards plugins' "results changed" signals to the panel, coalescing a burst into one new search.
final class ResultsChangedRelay {
    static let delay: Duration = .milliseconds(100)

    var handler: () -> Void = {}
    private var pending: Task<Void, Never>?

    func signal() {
        guard pending == nil else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            self?.pending = nil
            self?.handler()
        }
    }
}

/// Forwards a plugin's `resultsChanged` with its id to the Settings banner, which reads its status again.
final class PluginStatusRelay {
    var handler: @MainActor (String) -> Void = { _ in }

    @MainActor func signal(_ pluginID: String) {
        handler(pluginID)
    }
}

/// Lets a plugin ask for its own Settings pane before the coordinator exists.
final class PluginSettingsRelay {
    var handler: @MainActor (String) -> Void = { _ in }
    /// `PluginContext.openModels`: the plugin id and the package id.
    var modelsHandler: @MainActor (String, String?) -> Void = { _, _ in }

    @MainActor func open(_ pluginID: String) {
        handler(pluginID)
    }

    @MainActor func openModels(_ pluginID: String, _ packageID: String?) {
        modelsHandler(pluginID, packageID)
    }
}
