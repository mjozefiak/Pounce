import AppKit
import PounceKit
import os

/// Composition root: builds the environment, the plugin host and the window controllers, and owns
/// them for the lifetime of the app.
final class AppCoordinator {
    let environment: AppEnvironment
    let host: PluginHost
    private(set) var statusItem: StatusItemController?
    private let logger = Logger(subsystem: "app.pounce", category: "app")

    init(environment: AppEnvironment, pluginTypes: [any PouncePlugin.Type] = PluginRegistry.all) {
        self.environment = environment
        self.host = PluginHost(
            pluginTypes: pluginTypes,
            makeContext: environment.makeContext(for:),
            settings: environment.settings
        )
    }

    /// Shows the menu bar item, then activates the enabled plugins.
    func start() async {
        let host = host
        statusItem = StatusItemController { host.activeCommands }
        await host.start()
        statusItem?.rebuildMenu()
        logger.info("Started with \(host.entries.count, privacy: .public) plugins")
    }

    /// Deactivates every plugin before the app exits.
    func stop() async {
        await host.stop()
    }
}
