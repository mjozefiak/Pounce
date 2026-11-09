import Foundation
import LintelKit
import SwiftUI
import Synchronization

/// Window management: workspaces, tiling and zone layouts (spec `2026-11-09-window-management`). Built in
/// steps; this is the skeleton of step 1.3 (manifest, settings, availability check). It is **not registered in
/// `PluginRegistry`** until the last step of Phase 1 (1.12), so no empty "Window Management" toggle reaches
/// users before the feature works.
///
/// Nothing moves unless the plugin is enabled and Accessibility is trusted. The failure mode of every problem is
/// a disabled feature with a banner, never a crash or a window left parked: plugin code never traps, window
/// titles and bundle ids never reach a log, `ranking.sqlite` or `state.json`. Settings: `plugins.windows.*`
/// (`WindowsSettings.Key`). Disabled by default.
@MainActor
public final class WindowsPlugin: LintelPlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "windows",
        displayName: LocalizedStringResource("Window Management", comment: "Plugin name of window management"),
        symbolName: "rectangle.3.group",
        order: 60,
        defaultEnabled: false,
        settingsGroup: .lintel,
        summary: LocalizedStringResource(
            "Arrange windows in workspaces.", comment: "Settings → Features: what Window Management does")
    )

    /// Why `activate()` refused to start.
    public enum StartError: Error, Equatable {
        /// The window client cannot work on this Mac (for example the window-id symbol is missing).
        case unsupported(reason: String)
        /// Two launches in a row ended with parked windows, so the plugin starts switched off (spec:
        /// Architecture, "Watchdog and safe mode"). Starting it again by hand clears the flag.
        case safeMode
    }

    let context: PluginContext
    let settings: WindowsSettings
    let hud: any WindowsHUDPresenting
    private let activationCenter: NotificationCenter
    private(set) var runtime: WindowsRuntime?
    /// The first activation of this process honours safe mode; a later one (the user switched the plugin on
    /// again, or pressed Try Again) clears it.
    private var launchActivationDone = false

    public convenience init(context: PluginContext) {
        self.init(context: context, hud: WindowsHUDPanel.shared, activationCenter: .default)
    }

    init(context: PluginContext, hud: any WindowsHUDPresenting, activationCenter: NotificationCenter) {
        self.context = context
        self.settings = WindowsSettings(context.settings)
        self.hud = hud
        self.activationCenter = activationCenter
        (hud as? WindowsHUDPanel)?.allowAccessibility = { [workspace = context.workspace] in
            guard let url = Self.accessibilitySettingsURL else { return }
            Task { try? await workspace.open(url) }
        }
    }

    /// System Settings, Privacy & Security, Accessibility.
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    public var requiredPermissions: Set<Permission> { [.accessibility] }

    /// Throws when the window client is `unsupported`, so the host marks the plugin `failed` (spec: API
    /// Contracts), and in safe mode on the first start of a launch. Then starts the engine.
    public func activate() async throws {
        if case .unsupported(let reason) = context.windows.availability {
            throw StartError.unsupported(reason: reason)
        }
        if settings.safeMode {
            if !launchActivationDone {
                launchActivationDone = true
                throw StartError.safeMode
            }
            settings.setSafeMode(false)
            settings.setParkedLaunches(0)
        }
        launchActivationDone = true
        guard runtime == nil else { return }
        let runtime = WindowsRuntime(
            context: context, settings: settings, hud: hud, activationCenter: activationCenter)
        self.runtime = runtime
        await runtime.start()
    }

    /// Puts every parked window back (waiting at most 5 s) and stops.
    public func deactivate() async {
        guard let runtime else { return }
        self.runtime = nil
        await runtime.stop()
    }

    /// *Restore all windows*: ends with the restore HUD. Without a running engine it works from the journal.
    func restoreAllWindows() async {
        if let runtime {
            await runtime.restoreAllWindows()
            return
        }
        let report = await Self.restoreFromJournal(context: context)
        hud.show(WindowsHUDState(report: report))
    }

    /// "Erase Data": puts every window back first; the host then deletes `Plugins/windows/`.
    public func eraseData() async throws {
        await deactivate()
        let report = await Self.restoreFromJournal(context: context)
        if report.remaining > 0 {
            context.logger.notice("Erasing window data with \(report.remaining, privacy: .public) windows not restored")
        }
    }

    // MARK: Recovery

    /// Runs once per launch for every registered plugin, enabled or not (spec: Architecture, "Recovery runs
    /// outside the plugin lifecycle"): reads the journal and puts every parked window back. `.deferred` while
    /// Accessibility is not trusted, so the journal stays and the host tries again on app activation.
    public nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        await recover(context: context, hud: { state in await MainActor.run { WindowsHUDPanel.shared.show(state) } })
    }

    /// `recoverAtLaunch` with the HUD injected (tests).
    nonisolated static func recover(
        context: PluginContext, isLaunch: Bool? = nil, hud: @Sendable (WindowsHUDState) async -> Void
    ) async -> RecoveryOutcome {
        // A running engine owns its journal.
        guard !ActiveEngines.contains(context.storageDirectory) else { return .done }
        let first = isLaunch ?? LaunchCounter.isFirstRun(for: context.storageDirectory)
        let report = await restoreFromJournal(context: context)
        let settings = WindowsSettings(context.settings)
        if first {
            // A launch that found parked windows is counted; the second in a row starts the plugin in safe mode.
            if report.isEmpty {
                settings.setParkedLaunches(0)
            } else {
                settings.setParkedLaunches(settings.parkedLaunches + 1)
                if settings.parkedLaunches >= 2 { settings.setSafeMode(true) }
            }
        }
        if report.restored > 0 || (first && !report.isEmpty) {
            await hud(WindowsHUDState(report: report))
        }
        return report.outcome
    }

    /// One pass over the journal in `context.storageDirectory` with a store of its own.
    nonisolated static func restoreFromJournal(context: PluginContext) async -> RecoveryReport {
        let store = StateStore(directory: context.storageDirectory, clock: context.clock)
        await store.load()
        guard await !store.hidden.isEmpty else { return RecoveryReport() }
        let trusted = await MainActor.run { context.permissions.status(of: .accessibility) == .granted }
        let report = await WindowRecovery.run(
            store: store, client: context.windows, trusted: trusted, logger: context.logger)
        await store.close()
        return report
    }
}

/// Which storage folders already ran their recovery in this process, so a retry does not count as a launch.
enum LaunchCounter {
    private static let seen = Mutex(Set<String>())

    static func isFirstRun(for directory: URL) -> Bool {
        seen.withLock { $0.insert(directory.standardizedFileURL.path).inserted }
    }
}

extension WindowsHUDPanel {
    /// One panel for the whole app: the recovery at launch (no plugin instance yet) and the running plugin show
    /// the same one.
    static let shared = WindowsHUDPanel()
}
