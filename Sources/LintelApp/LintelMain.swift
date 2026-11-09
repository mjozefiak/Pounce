import AppKit
import LintelKit
import os

@main
enum LintelMain {
    static func main() {
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
            await coordinator.start()
            started = true
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

    /// A `.lintellayouts` file opened with Lintel goes to the layout importer (Window Management). Before the
    /// plugins have started it waits for them.
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
            schedule(after: quitAfter) { [weak self] in
                self?.coordinator?.statusItem?.closeMenu()
                NSApp.terminate(nil)
            }
        }
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
