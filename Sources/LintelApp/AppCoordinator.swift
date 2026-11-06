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
    /// The shell panes' views in the main window's Settings mode.
    private var shellPane: ((SettingsShellPane) -> AnyView)?
    private(set) var onboarding: OnboardingController?
    private(set) var about: AboutWindowController?
    /// The main window (ADR 0008; enabled in every build since step 6.3a): built on first use.
    private(set) var mainWindow: MainWindowController?
    private var mainMenu: MainMenuController?
    /// The one banner of the main window's Settings mode (spec step 2.2); built with the Settings mode.
    private var settingsHost: SettingsHostModel?
    /// Settings → Models (spec step 3.2).
    private var modelsPane: ModelsPaneModel?
    /// Shows the welcome screen's pending steps. Set in `start()` outside QA mode; tests replace it.
    var presentPendingOnboarding: (@MainActor () -> Void)?
    private let search: SearchCoordinator
    private let settingsRelay: PluginSettingsRelay
    /// `PluginContext.resultsChanged` with the plugin's id, for the Settings banner.
    private let statusRelay = PluginStatusRelay()
    /// `PluginContext.noteSources`, `noteSourcesChanged` and `openNote` (the Notes workspace).
    private let noteSourcesRelay = NoteSourcesRelay()
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
        let noteRelay = noteSourcesRelay
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
                    openModels: { packageID in settingsRelay.openModels(manifest.id.rawValue, packageID) },
                    availableCommands: { noteRelay.commands() },
                    noteSources: { noteRelay.sources() },
                    noteSourcesChanged: { noteRelay.changes() },
                    openNote: { key in noteRelay.openNote(WorkspaceRoute(kind: "openNote", id: key.rawValue)) },
                    keptNoteCopies: { owner in await noteRelay.keptCopies(owner) },
                    deleteKeptNoteCopies: { owner, erased in await noteRelay.deleteKeptCopies(owner, erased) }
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
        settingsRelay.handler = { [weak self] id in self?.openSettings(pane: id) }
        settingsRelay.modelsHandler = { [weak self] id, packageID in self?.openModels(from: id, packageID: packageID) }
        statusRelay.handler = { [weak self] id in self?.settingsHost?.pluginResultsChanged(id) }
        let host = host
        let logger = logger
        var reported = Set<String>()
        noteRelay.sources = {
            Self.activeNoteSources(
                host, report: { if reported.insert($0).inserted { logger.error("\($0, privacy: .public)") } })
        }
        noteRelay.openNote = { [weak self] route in self?.openNote(route) ?? false }
        noteRelay.commands = { [weak self] in self?.paletteCommands() ?? [] }
        noteRelay.keptCopies = { [weak self] owner in await self?.host.keptNoteCopies(ofOwner: owner) ?? 0 }
        noteRelay.deleteKeptCopies = { [weak self] owner, erased in
            await self?.host.deleteKeptNoteCopies(ofOwner: owner, ownerErased: erased) ?? true
        }
        observeNoteSources()
    }

    /// The commands of the Notes palette: every active plugin command that is not a key-event command, with its
    /// current shortcut, then Open Settings (⌘,). A `panelMode` command opens the launcher panel in that mode.
    func paletteCommands() -> [CommandInfo] {
        var commands = host.activeCommands.filter { $0.onKeyEvent == nil }.map { command in
            CommandInfo(
                title: command.title,
                shortcut: hotkeys.commandShortcut(command.id)?.keyShortcut,
                run: { [weak self] in self?.perform(command) })
        }
        commands.append(
            CommandInfo(
                title: LocalizedStringResource("Open Settings", comment: "Command palette: opens Settings"),
                shortcut: KeyShortcut(key: ",", modifiers: [.command]),
                run: { [weak self] in self?.openSettings() }))
        return commands
    }

    /// The active plugins' note sources. A source whose `pluginID` is not its plugin's id, and any later source
    /// of an id already taken, is dropped and reported once.
    static func activeNoteSources(_ host: PluginHost, report: (String) -> Void = { _ in }) -> [any NoteSource] {
        var taken = Set<PluginID>()
        var result: [any NoteSource] = []
        for entry in host.entries where entry.state.isActive {
            for source in entry.plugin.noteSources {
                guard source.pluginID == entry.manifest.id else {
                    report("note source dropped: id does not match its plugin \(entry.manifest.id.rawValue)")
                    continue
                }
                guard taken.insert(source.pluginID).inserted else {
                    report("note source dropped: duplicate id \(source.pluginID.rawValue)")
                    continue
                }
                result.append(source)
            }
        }
        return result
    }

    /// Tells Notes when a plugin was switched on or off, failed or recovered: its set of sources changed.
    private func observeNoteSources() {
        withObservationTracking {
            _ = host.entries.map(\.state)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.noteSourcesRelay.signalChanged()
                self.observeNoteSources()
            }
        }
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
            if !showInDock { self?.mainWindow?.bringToFrontIfVisible() }
            // Changing the activation policy can drop the main menu; put it back for the key window.
            self?.mainMenu?.refresh()
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

    /// Sends the Dock, Command-comma, "Settings…", the Settings panes, `openModels` and `openNote` to the main
    /// window (ADR 0008, "Release gate"; enabled in every build since step 6.3a).
    private(set) lazy var router = makeRouter()

    /// A click on the Dock icon (or opening the app again from Finder): the main window, unless a window is already
    /// open.
    func reopen() {
        router.reopen(visibleWindowRoles: visibleWindowRoles())
    }

    /// Command-comma in the launcher panel and the status item's "Settings…".
    func openSettingsFromMenu() {
        router.openSettings()
    }

    /// `PluginContext.openModels` of the plugin `pluginID`.
    func openModels(from pluginID: String, packageID: String?) {
        router.openModels(packageID: packageID)
        // A Models pane that exists scrolls to the row now (it may be on screen already); otherwise it takes the
        // pending row when it appears.
        if let modelsPane, let target = router.takePendingModelsPackageID() { modelsPane.scrollTarget = target }
    }

    /// An `openNote` route (kind `openNote`, `WorkspaceSection.handleRoute`): `true` only when a section of the
    /// main window handled it; the caller keeps its old behaviour otherwise.
    @discardableResult
    func openNote(_ route: WorkspaceRoute) -> Bool {
        router.open(route)
    }

    /// The active plugins' workspace sections, by `order`.
    private static func activeWorkspaceSections(_ host: PluginHost) -> [WorkspaceSection] {
        host.entries.filter(\.state.isActive).flatMap(\.plugin.workspaceSections).sorted { $0.order < $1.order }
    }

    private func visibleWindowRoles() -> [KeyWindowRole] {
        DockPresence.appWindowRoles(NSApp.windows.filter(\.isVisible), mainWindow: mainWindow?.window)
    }

    private func makeRouter() -> MainWindowRouter {
        let host = host
        var targets = MainWindowRouter.Targets()
        targets.sections = { Self.activeWorkspaceSections(host) }
        targets.showMainWindow = { [weak self] in self?.showMainWindow { $0.show() } }
        targets.showMainWindowSettings = { [weak self] pane in self?.showMainWindow { $0.showSettings(pane) } }
        targets.showMainWindowSection = { [weak self] id in self?.showMainWindow { $0.showWorkspace(id) } }
        return MainWindowRouter(targets: targets)
    }

    /// Deactivates every plugin before the app exits.
    func stop() async {
        // The visible workspace section flushes what it holds before the plugins stop.
        await mainWindow?.prepareForTermination()
        await host.stop()
    }

    /// Hides the panel first, refreshes the default shortcut (Spotlight may have released ⌘Space), and
    /// shows a shell pane of the main window's Settings mode.
    func openSettings(_ pane: SettingsShellPane = .general) {
        router.openSettings(pane: pane.rawValue)
    }

    /// The plugin panes of the main window's Settings mode, disabled and failed plugins included, drawn dimmed
    /// (spec steps 1.2 and 1.3).
    func mainWindowPluginPanes() -> [SettingsPluginPane] {
        host.settingsPanes()
    }

    /// Hides the panel first and shows the About window with the third-party notices.
    func showAbout() {
        panelModel.hide()
        about?.show()
    }

    /// Shows a plugin's own pane, or a shell pane by its id, in the main window's Settings mode.
    func openSettings(pane id: String) {
        router.openSettings(pane: id)
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
        panelModel.openPluginSettings = { [weak self] id in self?.openSettings(pane: id.rawValue) }
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
        let shell: (SettingsShellPane) -> AnyView = { [environment, weak self] pane in
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
                        controls: AdvancedControls(
                            usage: environment.usage,
                            showWelcome: { self?.onboarding?.showAllSteps() },
                            showAbout: { self?.showAbout() }
                        ) { self?.panelModel.resultsChanged() }))
            }
        }
        shellPane = shell

        let onboarding = OnboardingController(hotkeys: hotkeys, settings: settings) {
            host.entries.filter(\.state.isActive).flatMap(\.plugin.onboardingSteps)
        }
        onboarding.activatesApp = environment.registersGlobalHotkeys
        onboarding.openMainWindow = { [weak self] in self?.router.openMainWindow() }
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

    /// Builds the main window on first use and shows it through `present`.
    private func showMainWindow(_ present: (MainWindowController) -> Void) {
        panelModel.hide()
        hotkeys.refreshDefault()
        present(mainWindow ?? makeMainWindow())
    }

    /// Settings mode: the sidebar, the one banner and the selected pane (`SettingsHost`).
    private func settingsModeContent(_ state: MainWindowState) -> AnyView {
        guard let shellPane else { return AnyView(EmptyView()) }
        let hasSection = state.section != nil
        let model: SettingsHostModel
        if let settingsHost {
            // A mode or selection change builds the panes again.
            settingsHost.reloadPanes()
            model = settingsHost
        } else {
            model = makeSettingsHost()
        }
        return AnyView(
            SettingsHost(
                model: model, shellPane: shellPane,
                modelsPane: { [weak self] in self?.modelsPaneView() ?? AnyView(EmptyView()) },
                selection: state.settingsPane,
                onSelect: { [weak self] id in self?.mainWindow?.selectSettingsPane(id) },
                onBack: hasSection ? { [weak self] in self?.mainWindow?.showWorkspace() } : nil))
    }

    private func makeSettingsHost() -> SettingsHostModel {
        var navigation = SettingsHostModel.Navigation()
        navigation.openModels = { [weak self] id, packageID in self?.openModels(from: id, packageID: packageID) }
        navigation.openURL = { url in NSWorkspace.shared.open(url) }
        navigation.pluginsChanged = { [weak self] in self?.pluginsChanged() }
        let models = modelsPaneModel()
        let model = SettingsHostModel(
            host: host, reader: environment.permissionsReader, navigation: navigation,
            panes: { [weak self] in self?.mainWindowPluginPanes() ?? [] },
            shellBanners: shellPaneBanners(models: models))
        settingsHost = model
        return model
    }

    /// The banners of the shell's own panes (spec step 4.1); Advanced has none.
    private func shellPaneBanners(models: ModelsPaneModel) -> [String: () -> StatusDerivation.Banner?] {
        let host = host
        let hotkeys = hotkeys
        let reader = environment.permissionsReader
        return [
            SettingsShellPane.general.rawValue: {
                ShellPaneBanners.general(shortcut: hotkeys.mainShortcut?.displayString)
            },
            SettingsShellPane.features.rawValue: { ShellPaneBanners.features(host: host) },
            SettingsShellPane.permissions.rawValue: {
                ShellPaneBanners.permissions(host: host, reader: reader)
            },
            MainWindowRouter.modelsPaneID: { models.banner },
        ]
    }

    /// Settings → Models over the real inventory (`ModelManagers.shared`), built once.
    private func modelsPaneModel() -> ModelsPaneModel {
        if let modelsPane { return modelsPane }
        let host = host
        let model = ModelsPaneModel(
            inventory: SharedModelInventory(modelsDirectory: environment.modelsDirectory),
            usages: { Self.modelUsages(host) },
            pickFolder: { Self.chooseModelFolder() }, modelsDirectory: environment.modelsDirectory,
            revealInFinder: { url in
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        modelsPane = model
        return model
    }

    private func modelsPaneView() -> AnyView {
        AnyView(ModelsPane(model: modelsPaneModel()) { [weak self] in self?.router.takePendingModelsPackageID() })
    }

    /// Every plugin's `modelUsage`, on or off: a disabled plugin's usage shows "(off)" and still guards removal.
    static func modelUsages(_ host: PluginHost) -> [ModelsPaneModel.PluginUsages] {
        host.entries.map { entry in
            ModelsPaneModel.PluginUsages(
                pluginID: entry.manifest.id.rawValue, pluginName: String(localized: entry.manifest.displayName),
                isEnabled: host.isEnabled(entry.manifest.id), usages: entry.plugin.modelUsage)
        }
    }

    private static func chooseModelFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button of the model folder picker")
        panel.message = String(
            localized: "Choose the folder that contains the model's files.",
            comment: "Message of the meetings model folder picker")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func makeMainWindow() -> MainWindowController {
        let host = host
        let window = MainWindowController(
            settings: environment.settings,
            sections: { Self.activeWorkspaceSections(host) },
            settingsPanes: { [weak self] in
                SettingsShellPane.allCases.map(\.rawValue) + [MainWindowRouter.modelsPaneID]
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

    /// QA (`--qa-snapshot`): the main window's content as a PNG, rendered by the app itself.
    func writeMainWindowSnapshotForQA(to path: String) {
        guard let view = mainWindow?.window?.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else {
            logger.error("No main window to snapshot")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        do {
            try data.write(to: URL(filePath: path))
        } catch {
            logger.error("Cannot write the snapshot: \(String(describing: error), privacy: .public)")
        }
    }

    /// QA: shows the whole welcome screen regardless of what was completed.
    func showOnboardingForQA() {
        onboarding?.showAllSteps()
    }

    /// QA: shows the whole welcome screen on one page: `intro`, `shortcut`, a plugin step id, or `done`.
    func showOnboardingStepForQA(_ id: String) {
        let steps = host.entries.filter(\.state.isActive).flatMap(\.plugin.onboardingSteps)
        guard
            OnboardingController.isKnownPage(id, pluginStepIDs: steps.map(\.id))
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

/// Forwards a plugin's `resultsChanged` with its id to the Settings banner, which reads its status (and every
/// plugin's for the sidebar dots) again. Like `ResultsChangedRelay`, the signals of one plugin within `delay` are
/// merged into one, so a burst (a copy, an indexing step) reads the statuses once.
final class PluginStatusRelay {
    static let delay: Duration = .milliseconds(100)

    var handler: @MainActor (String) -> Void = { _ in }
    /// Waits out the merge window; tests pass a gate they open themselves.
    private let wait: @MainActor () async -> Void
    private var pending: [String: Task<Void, Never>] = [:]

    init(wait: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: PluginStatusRelay.delay) }) {
        self.wait = wait
    }

    @MainActor func signal(_ pluginID: String) {
        guard pending[pluginID] == nil else { return }
        let wait = wait
        pending[pluginID] = Task { [weak self] in
            await wait()
            guard let self else { return }
            self.pending[pluginID] = nil
            self.handler(pluginID)
        }
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
