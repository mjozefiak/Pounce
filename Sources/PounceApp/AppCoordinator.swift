import AppKit
import PounceKit
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
    private let search: SearchCoordinator
    private let icons: IconCache
    private let logger = Logger(subsystem: "app.pounce", category: "app")

    /// - Parameters:
    ///   - registrar: where global shortcuts go; QA mode passes one that registers nothing.
    ///   - occupiedShortcuts: the shortcuts the system holds (symbolic hotkeys 64 and 65).
    init(
        environment: AppEnvironment,
        pluginTypes: [any PouncePlugin.Type] = PluginRegistry.all,
        registrar: any HotkeyRegistrar,
        occupiedShortcuts: @escaping () -> Set<HotkeyShortcut>,
        launchAtLogin: any LaunchAtLoginClient
    ) {
        self.environment = environment
        let relay = ResultsChangedRelay()
        self.host = PluginHost(
            pluginTypes: pluginTypes,
            makeContext: { manifest in
                environment.makeContext(for: manifest) {
                    Task { @MainActor in relay.signal() }
                }
            },
            settings: environment.settings
        )
        self.appSettings = AppSettings(store: environment.settings)
        self.hotkeys = HotkeyService(
            registrar: registrar, settings: environment.settings, readOccupied: occupiedShortcuts)
        self.launchAtLogin = launchAtLogin
        let search = SearchCoordinator(host: host, usage: environment.usage)
        self.search = search
        let panelModel = PanelModel { query in await search.search(query) }
        self.panelModel = panelModel
        relay.handler = { [weak panelModel] in panelModel?.resultsChanged() }
        self.icons = IconCache(
            diskDirectory: environment.cachesRoot.appending(path: "icons", directoryHint: .isDirectory))
    }

    /// Builds the panel and windows, activates the enabled plugins, registers shortcuts and, on first
    /// launch, shows the Shortcut step.
    func start() async {
        let host = host
        statusItem = StatusItemController(
            actions: ShellMenuActions(
                openPanel: { [weak self] in self?.panelModel.show() },
                openSettings: { [weak self] in self?.openSettings() },
                mainShortcut: { [weak self] in self?.hotkeys.mainShortcut },
                runCommand: { [weak self] command in self?.perform(command) }
            )
        ) { host.activeCommands }

        buildPanel()
        buildWindows()

        await host.start()
        hotkeys.start { [weak self] in self?.panelModel.toggle() }
        syncCommands()
        statusItem?.rebuildMenu()
        logger.info("Started with \(host.entries.count, privacy: .public) plugins")

        if environment.registersGlobalHotkeys, !appSettings.shortcutOnboardingCompleted {
            onboarding?.showShortcutStep()
        }
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

    private func syncCommands() {
        hotkeys.syncCommands(host.activeCommands) { [weak self] command in self?.perform(command) }
    }

    private func buildPanel() {
        panelModel.textSize = appSettings.textSize
        panelModel.previousApplication = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        panelModel.openSettings = { [weak self] in self?.openSettings(.features) }
        let host = host
        let controller = PanelController(
            model: panelModel,
            icons: icons,
            level: appSettings.panelLevel
        ) { id in
            host.activePanelModes.first { $0.id == id }?.makeView()
        }
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
                AnyView(FeaturesPane(host: host) { self?.pluginsChanged() })
            },
            pluginPanes: {
                host.entries.compactMap { entry in
                    guard entry.state.isActive, let view = entry.plugin.settingsPane() else { return nil }
                    return SettingsWindowController.PluginPane(
                        id: entry.manifest.id.rawValue,
                        title: String(localized: entry.manifest.displayName),
                        symbolName: entry.manifest.symbolName,
                        view: view
                    )
                }
            }
        )
        window.activatesApp = environment.registersGlobalHotkeys
        settingsWindow = window

        let onboarding = OnboardingController(hotkeys: hotkeys, settings: settings)
        onboarding.activatesApp = environment.registersGlobalHotkeys
        self.onboarding = onboarding
    }

    private func pluginsChanged() {
        syncCommands()
        statusItem?.rebuildMenu()
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
    /// QA: shows the onboarding step regardless of the first-launch flag.
    func showOnboardingForQA() {
        onboarding?.showShortcutStep()
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
