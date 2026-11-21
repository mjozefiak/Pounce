import AppKit
import LintelKit
import os

@main
enum LintelMain {
    static func main() {
        #if DEBUG
        // Before anything is created or read: the QA bundle without --qa must not touch the real app's data.
        if case .refuse(let reason) = QAIdentityGuard.decisionForThisProcess() {
            Logger(subsystem: "com.lintelapp", category: "app").fault("\(reason, privacy: .public)")
            FileHandle.standardError.write(Data((reason + "\n").utf8))
            exit(EX_USAGE)
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Info.plist sets LSUIElement for the bundled app; this covers `swift run` as well.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    private var updates: UpdateController?
    /// Files opened before the coordinator has started (a double-click that launched the app).
    private var pendingFiles: [URL] = []
    private var started = false
    private let logger = Logger(subsystem: "com.lintelapp", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let environment: AppEnvironment
        do {
            environment = try makeEnvironment()
        } catch {
            logger.fault("Cannot prepare the data directory: \(String(describing: error), privacy: .public)")
            presentFatalAlert(error)
            NSApp.terminate(nil)
            return
        }
        let coordinator = makeCoordinator(environment)
        self.coordinator = coordinator
        Task {
            #if DEBUG
            await recordQAUses(environment)
            #endif
            // Before the plugins start, so a moved copy never runs next to a started one.
            guard await offerMoveToApplications(environment) else { return }
            await coordinator.start()
            started = true
            // `UpdaterStartPolicy` decides; DEBUG and QA builds never start the real updater.
            let updates = makeUpdateController(environment, host: coordinator.host)
            coordinator.attach(updates)
            // Not while the welcome screen is up: Sparkle's permission question must not appear over it (D6).
            updates.welcomeIsPending = { [weak coordinator] in coordinator?.onboarding?.isVisible ?? false }
            #if DEBUG
            if qaOptions?.updatesWelcomePending == true {
                let pending = QAWelcomePending()
                updates.welcomeIsPending = { pending.value }
                Task { @MainActor [weak updates] in
                    try? await Task.sleep(for: .seconds(8))
                    pending.value = false
                    updates?.welcomeFinished()
                }
            }
            #endif
            updates.startIfAllowed()
            self.updates = updates
            if !pendingFiles.isEmpty {
                let files = pendingFiles
                pendingFiles = []
                await coordinator.open(files)
            }
            #if DEBUG
            runQAActions()
            #endif
        }
    }

    /// The real updater, or in a QA run with `--qa-update-available` a fake that reports a found update at once.
    private func makeUpdateController(_ environment: AppEnvironment, host: PluginHost) -> UpdateController {
        let isBusy = { host.busyReason != nil }
        #if DEBUG
        if let options = qaOptions, options.updateAvailable != nil || options.updatesOn == true {
            return QAUpdateChecker.controller(
                version: options.updateAvailable, beta: options.updatesBeta, settings: environment.settings,
                isBusy: isBusy)
        }
        #endif
        return UpdateController.live(settings: environment.settings, isBusy: isBusy)
    }

    /// A file opened with Lintel goes to the plugins (`PluginHost.openFile`). Before the plugins have started it
    /// waits for them.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard started, let coordinator else {
            pendingFiles.append(contentsOf: urls)
            return
        }
        Task { await coordinator.open(urls) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator?.reopen()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        Task {
            await coordinator.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func makeEnvironment() throws -> AppEnvironment {
        #if DEBUG
        if let options = try QAOptions.parse(ProcessInfo.processInfo.arguments) {
            qaOptions = options
            if let appearance = options.appearance {
                NSApp.appearance = NSAppearance(named: appearance.name)
            }
            return try AppEnvironment.qa(options)
        }
        #endif
        return try AppEnvironment.live()
    }

    /// The live app registers global shortcuts and Launch at Login; QA mode gets in-memory stand-ins.
    private func makeCoordinator(_ environment: AppEnvironment) -> AppCoordinator {
        #if DEBUG
        if let options = qaOptions {
            let occupied: Set<HotkeyShortcut>
            switch options.spotlightHoldsCommandSpace {
            case true?: occupied = [.commandSpace, .optionCommandSpace]
            case false?: occupied = []
            case nil: occupied = SymbolicHotkeys.occupiedShortcuts(SymbolicHotkeys.readSystem())
            }
            return AppCoordinator(
                environment: environment,
                registrar: PreviewHotkeyRegistrar(),
                occupiedShortcuts: { occupied },
                launchAtLogin: InMemoryLaunchAtLogin()
            )
        }
        #endif
        return AppCoordinator(
            environment: environment,
            registrar: KeyboardShortcutsRegistrar(),
            occupiedShortcuts: { SymbolicHotkeys.occupiedShortcuts(SymbolicHotkeys.readSystem()) },
            launchAtLogin: SystemLaunchAtLogin()
        )
    }

    /// The "Move Lintel to Applications?" alert, once per launch (spec `2026-11-19-updates-and-open-source-hygiene`, step 4.2).
    /// Release builds only; DEBUG builds and QA mode never show it, except QA with `--qa-move-prompt`, which uses
    /// fakes and never quits. Returns whether the launch goes on (`false` once the moved copy was opened).
    private func offerMoveToApplications(_ environment: AppEnvironment) async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if DEBUG
        guard let options = qaOptions, options.showsMovePrompt else { return true }
        // The alert is modal and comes before `runQAActions`, so `--qa-quit-after` gets its own timer here.
        if let quitAfter = options.quitAfter {
            schedule(after: quitAfter) { [weak self] in
                self?.qaQuitDuringMovePrompt = true
                self?.closeModalForQA(snapshotPath: options.snapshotPath)
            }
        }
        let fakes = QAInstallFakes(scenario: options.moveScenario)
        var prompt = MoveToApplicationsPrompt(
            settings: environment.settings,
            mover: MoveToApplications(
                files: fakes, processes: fakes, quarantine: fakes, relauncher: fakes, versions: fakes))
        prompt.ask = { MoveToApplicationsPrompt.presentAlert($0, activates: false) }
        prompt.report = { MoveToApplicationsPrompt.presentFailure($0, activates: false) }
        let outcome = await prompt.offerIfNeeded(bundleURL: QAInstallFakes.bundleURL, home: home)
        logger.info("QA move prompt: \(String(describing: outcome), privacy: .public)")
        if qaQuitDuringMovePrompt {
            SystemAppRelauncher().quit()
            return false
        }
        // The fakes never quit, so QA goes on with the launch whatever the answer.
        return true
        #else
        var mover = MoveToApplications(
            files: SystemInstallFileManager(), processes: SystemRunningAppListing(),
            quarantine: SystemQuarantineRemover(), relauncher: SystemAppRelauncher(),
            versions: SystemBundleVersionReader())
        // Files opened while the alert is up go to the moved copy; if its open fails they open here as usual.
        mover.pendingFiles = { [weak self] in self?.pendingFiles ?? [] }
        let prompt = MoveToApplicationsPrompt(
            settings: environment.settings,
            mover: mover)
        return await prompt.offerIfNeeded(bundleURL: Bundle.main.bundleURL, home: home)
            .continuesLaunch
        #endif
    }

    private func presentFatalAlert(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Lintel cannot start",
            comment: "Alert title when the app cannot prepare its data directory"
        )
        alert.informativeText = error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    #if DEBUG
    private var qaOptions: QAOptions?
    /// `--qa-quit-after` fired while the `--qa-move-prompt` alert was up.
    private var qaQuitDuringMovePrompt = false

    private func runQAActions() {
        guard let options = qaOptions else { return }
        logger.info("QA mode, data root \(self.coordinator?.environment.dataRoot.path ?? "-", privacy: .public)")
        if options.showsMenu {
            // Delay so the status item is laid out in the menu bar before the menu opens.
            schedule(after: .milliseconds(600)) { [weak self] in
                self?.coordinator?.statusItem?.openMenu()
            }
        }
        if options.showsOnboarding {
            coordinator?.showOnboardingForQA()
        }
        if let step = options.onboardingStep {
            coordinator?.showOnboardingStepForQA(step)
        }
        if options.showsAbout {
            coordinator?.showAbout()
        }
        // `--qa-settings <pane>` selects the pane in the main window's Settings mode; with `--qa-window settings`
        // the window opens on that pane below.
        if let pane = options.settingsPane, options.windowMode != .settings {
            coordinator?.openSettings(pane: pane)
        }
        if let mode = options.windowMode {
            coordinator?.showMainWindowForQA(mode, settingsPane: options.settingsPane)
        }
        if let mode = options.panelMode {
            let panelMode: PanelModel.Mode = mode == "search" ? .search : .plugin(PanelModeID(rawValue: mode))
            coordinator?.panelModel.show(mode: panelMode)
            if let query = options.query {
                coordinator?.panelModel.updateQuery(query)
            }
            if options.failsAction, let model = coordinator?.panelModel {
                Task {
                    await model.waitForSearch()
                    guard let action = model.selectedActions.first else { return }
                    model.actionFailed(action, itemTitle: model.selectedItem?.candidate.title)
                }
            }
            if options.confirmsAction, let model = coordinator?.panelModel {
                Task {
                    // A seeded list (for example `plugins.clipboard.qaSeed`) reloads once after launch, and a
                    // reload cancels the confirmation: wait for it to settle first.
                    try? await Task.sleep(for: .seconds(2))
                    await model.waitForSearch()
                    model.showConfirmationForQA()
                }
            }
        }
        if let quitAfter = options.quitAfter {
            let snapshotPath = options.snapshotPath
            schedule(after: quitAfter) { [weak self] in
                if let snapshotPath { self?.coordinator?.writeMainWindowSnapshotForQA(to: snapshotPath) }
                self?.coordinator?.statusItem?.closeMenu()
                NSApp.terminate(nil)
            }
        }
    }

    /// `--qa-quit-after` while the `--qa-move-prompt` alert runs: snapshots the alert instead of the main window when
    /// `--qa-snapshot` is set, then ends the modal session so the app can quit.
    private func closeModalForQA(snapshotPath: String?) {
        guard let window = NSApp.modalWindow else { return }
        if let snapshotPath, let view = window.contentView?.superview ?? window.contentView,
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                do {
                    try data.write(to: URL(filePath: snapshotPath))
                } catch {
                    logger.error("Cannot write the snapshot: \(String(describing: error), privacy: .public)")
                }
            }
        }
        NSApp.abortModal()
    }

    /// `--qa-record-use`: seeds the QA ranking database before the plugins start.
    private func recordQAUses(_ environment: AppEnvironment) async {
        guard let options = qaOptions else { return }
        for raw in options.recordedUses {
            guard let key = ItemKey(rawValue: raw) else {
                logger.error("Ignoring invalid --qa-record-use key \(raw, privacy: .public)")
                continue
            }
            do {
                try await environment.usage.recordUse(of: key, queryPrefix: nil, at: Date())
            } catch {
                logger.error("Cannot record a QA use: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// A run-loop timer in the common modes, so it also fires while a menu is tracking.
    private func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    #endif
}
