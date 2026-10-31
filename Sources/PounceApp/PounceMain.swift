import AppKit
import os

@main
enum PounceMain {
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
    private let logger = Logger(subsystem: "app.pounce", category: "app")

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
        let coordinator = AppCoordinator(environment: environment)
        self.coordinator = coordinator
        Task {
            await coordinator.start()
            #if DEBUG
            runQAActions()
            #endif
        }
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

    private func presentFatalAlert(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "Pounce cannot start",
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
        if let quitAfter = options.quitAfter {
            schedule(after: quitAfter) { [weak self] in
                self?.coordinator?.statusItem?.closeMenu()
                NSApp.terminate(nil)
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
