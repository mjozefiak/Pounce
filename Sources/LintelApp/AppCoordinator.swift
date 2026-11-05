import AppKit
import LintelKit
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
    private(set) var onboarding: OnboardingController?
    private(set) var about: AboutWindowController?
    #if DEBUG
    /// The main window, behind the release gate of ADR 0008 until step 6.3: built on first use, DEBUG only.
    private(set) var mainWindow: MainWindowController?
    #endif
    /// Shows the welcome screen's pending steps. Set in `start()` outside QA mode; tests replace it.
    var presentPendingOnboarding: (@MainActor () -> Void)?
    private let search: SearchCoordinator
    private let settingsRelay: PluginSettingsRelay
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
                    resultsChanged: { Task { @MainActor in relay.signal() } },
                    makeShortcutRecorder: { commandID in
                        AnyView(CommandShortcutRecorder(hotkeys: hotkeys, commandID: commandID))
                    },
                    claimEscapeKey: { onEscape in hotkeys.claimEscape(onEscape) },
                    openSettings: { settingsRelay.open(manifest.id.rawValue) }
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
    }

    /// Builds the panel and windows, activates the enabled plugins, registers shortcuts and, while steps
    /// are pending, shows the welcome screen.
    func start() async {
        let host = host
        statusItem = StatusItemController(
            actions: ShellMenuActions(
                openPanel: { [weak self] in self?.panelModel.show() },
                openSettings: { [weak self] in self?.openSettings() },
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

    /// A click on the Dock icon (or opening the app again from Finder) opens Settings.
    func reopen() {
        openSettings()
    }

    /// Deactivates every plugin before the app exits.
    func stop() async {
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
        panelModel.previousApplication = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        panelModel.openSettings = { [weak self] in self?.openSettings(.features) }
        panelModel.openPluginSettings = { [weak self] id in self?.openPluginSettings(id.rawValue) }
        let host = host
        panelModel.panelMode = { id in host.activePanelModes.first { $0.id == id } }
        let search = search
        panelModel.modeSearch = { mode, text, filter in await search.search(mode: mode, raw: text, filter: filter) }
        let controller = PanelController(model: panelModel, icons: icons, level: appSettings.panelLevel)
        controller.takesKeyFocus = environment.registersGlobalHotkeys
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        panel = controller
        observeTextSize()
    }

    private func buildWindows() {
        let hotkeys = hotkeys
        let settings = appSettings
        let launchAtLogin = launchAtLogin
        let host = host
        let window = SettingsWindowController(
            general: {
                AnyView(GeneralPane(hotkeys: hotkeys, settings: settings, launchAtLogin: launchAtLogin))
            },
            features: { [weak self] in
                AnyView(FeaturesPane(host: host, settings: settings) { self?.pluginsChanged() })
            },
            permissions: { [environment] in
                let model = PermissionsModel(host: host, reader: environment.permissionsReader) { url in
                    NSWorkspace.shared.open(url)
                }
                return AnyView(PermissionsPane(model: model))
            },
            advanced: { [environment, weak self] in
                AnyView(
                    AdvancedPane(
                        controls: AdvancedControls(usage: environment.usage) { self?.panelModel.resultsChanged() }))
            },
            // The old window keeps skipping inactive plugins until it is removed (spec step 6.3).
            pluginPanes: { host.settingsPanes(includingInactive: false) }
        )
        window.activatesApp = environment.registersGlobalHotkeys
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
    /// QA (`--qa-window`): opens the main window in a mode. Not reachable from anything else until step 1.5.
    func showMainWindowForQA(_ mode: MainWindowState.Mode) {
        panelModel.hide()
        let window = mainWindow ?? makeMainWindow()
        switch mode {
        case .workspace: window.showWorkspace()
        case .settings: window.showSettings()
        }
    }

    private func makeMainWindow() -> MainWindowController {
        let host = host
        let window = MainWindowController(
            settings: environment.settings,
            sections: {
                host.entries.filter(\.state.isActive).flatMap(\.plugin.workspaceSections).sorted { $0.order < $1.order }
            },
            settingsPanes: { [weak self] in
                SettingsWindowController.Pane.allCases.map(\.rawValue) + (self?.mainWindowPluginPanes().map(\.id) ?? [])
            },
            // QA mode never writes the frame into the tester's defaults.
            frameAutosaveName: environment.registersGlobalHotkeys ? MainWindowController.autosaveName : nil,
            makeContent: { state, sections in
                // Step 1.3 hosts the Settings panes here.
                guard state.mode == .workspace, let section = sections.first(where: { $0.id == state.section })
                else { return AnyView(EmptyView()) }
                return section.makeView()
            }
        )
        window.activatesApp = environment.registersGlobalHotkeys
        mainWindow = window
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

/// Lets a plugin ask for its own Settings pane before the coordinator exists.
final class PluginSettingsRelay {
    var handler: @MainActor (String) -> Void = { _ in }

    @MainActor func open(_ pluginID: String) {
        handler(pluginID)
    }
}
