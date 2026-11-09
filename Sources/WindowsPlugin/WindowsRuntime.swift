import Foundation
import LintelKit
import LintelUI
import Synchronization
import os

/// The storage folders whose engine is running right now. `recoverAtLaunch` (which runs outside the plugin's
/// lifecycle and may run again on app activation) leaves the journal of a running engine to that engine: the
/// parked windows in it are parked on purpose.
enum ActiveEngines {
    private static let paths = Mutex(Set<String>())

    static func insert(_ directory: URL) { paths.withLock { _ = $0.insert(directory.standardizedFileURL.path) } }
    static func remove(_ directory: URL) { paths.withLock { _ = $0.remove(directory.standardizedFileURL.path) } }
    static func contains(_ directory: URL) -> Bool {
        paths.withLock { $0.contains(directory.standardizedFileURL.path) }
    }
}

/// Everything the plugin runs while it is active: the engine over the context's window client, the journal
/// store, the Accessibility tracker and the HUD. It exists only between `activate()` and `deactivate()`, so a
/// plugin that is off holds no store, no observer and no task.
@MainActor
final class WindowsRuntime {
    /// How long a disable or a quit waits for windows to be put back; what is left stays in the journal for the
    /// next launch (spec: Architecture, "Recovery runs outside the plugin lifecycle").
    static let stopBudget: Duration = .seconds(5)

    let context: PluginContext
    let settings: WindowsSettings
    let store: StateStore
    let engine: WindowEngine
    let trust: AccessibilityTrust
    private let hud: any WindowsHUDPresenting
    private var activationObserver: AppActivationObserver?

    init(
        context: PluginContext, settings: WindowsSettings, hud: any WindowsHUDPresenting,
        activationCenter: NotificationCenter = .default, tick: Duration = .milliseconds(30)
    ) {
        self.context = context
        self.settings = settings
        self.hud = hud
        let store = StateStore(directory: context.storageDirectory, clock: context.clock)
        self.store = store
        let trust = AccessibilityTrust(reader: context.permissions, clock: context.clock)
        self.trust = trust
        let flag = trust.flag
        engine = WindowEngine(
            client: context.windows, store: store, clock: context.clock, workspaceCount: settings.workspaceCount,
            config: Self.config(settings), tick: tick,
            outputs: EngineOutputs(
                hud: { _, _ in },
                summary: { _ in },
                banner: { _ in },
                restored: { report in
                    Task { @MainActor in hud.show(WindowsHUDState(report: report)) }
                }),
            canMove: { flag.isTrusted }, logger: context.logger)
        self.activationCenter = activationCenter
    }

    private let activationCenter: NotificationCenter

    static func config(_ settings: WindowsSettings) -> EngineConfig {
        var config = EngineConfig()
        config.followFocus = settings.followFocus
        config.floatingBundleIDs = Set(settings.floatingApps)
        return config
    }

    func start() async {
        trust.refresh()
        trust.onChange = { [weak self] trusted in self?.trustChanged(trusted) }
        let engine = engine
        trust.startPolling { await engine.hasParkedWindows() }
        activationObserver = AppActivationObserver(center: activationCenter) { [weak self] in
            self?.trust.refresh()
        }
        ActiveEngines.insert(context.storageDirectory)
        await engine.start()
    }

    /// Puts the windows back and stops, waiting at most `stopBudget`.
    func stop() async {
        activationObserver?.stop()
        activationObserver = nil
        trust.stop()
        let engine = engine
        _ = await TimeBound.run(budget: Self.stopBudget, clock: context.clock) { await engine.stop() }
        ActiveEngines.remove(context.storageDirectory)
    }

    /// *Restore all windows*: always ends with the restore HUD.
    func restoreAllWindows() async {
        trust.refresh()
        let report = await engine.restoreAllWindows()
        hud.show(WindowsHUDState(report: report))
    }

    func applySettings() async {
        await engine.update(config: Self.config(settings))
        await engine.send(.setWorkspaceCount(settings.workspaceCount))
    }

    /// Accessibility came back: windows parked before it was revoked are restored at once, which is the only safe
    /// thing to do after a gap in which the user may have moved anything.
    private func trustChanged(_ trusted: Bool) {
        guard trusted else { return }
        Task { [engine, hud] in
            let report = await engine.restoreAllWindows()
            if !report.isEmpty { hud.show(WindowsHUDState(report: report)) }
        }
    }
}
