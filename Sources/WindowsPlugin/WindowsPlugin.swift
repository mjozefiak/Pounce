import AppKit
import Foundation
import LintelKit
import SwiftUI
import Synchronization

/// Window management: workspaces, tiling and zone layouts (spec `2026-11-09-window-management`), registered in
/// `PluginRegistry` and off by default.
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
        /// An earlier run is still putting windows back (a hung app held up its stop), so this one cannot start
        /// yet; Try Again works once it is done.
        case stillStopping
        /// The start ended with another error (only its type is kept: a message could carry a path or a title).
        case failed(reason: String)
    }

    let context: PluginContext
    let settings: WindowsSettings
    let hud: any WindowsHUDPresenting
    /// The strategies of the layout kinds: the one registry the runtime, the pane and the Layouts window use.
    let registry: LayoutRegistry
    private let activationCenter: NotificationCenter
    /// The owner of this plugin's storage folder: the only holder of its `StateStore`.
    let journal: JournalOwner
    /// Whether the plugin shows the menu bar strip when it is on. Tests leave it off: a status item needs a display.
    private let showsStrip: Bool
    /// Whether the plugin builds the snap overlay (a panel per display). Tests leave it off, like the strip.
    private let showsOverlay: Bool
    private(set) var runtime: WindowsRuntime?
    private(set) var lastStartError: StartError?
    /// Built on first use; creating it reads settings only.
    private(set) lazy var paneModel: WindowsSettingsModel = {
        let model = WindowsSettingsModel(
            context: context, settings: settings, registry: registry, runtime: { [weak self] in self?.runtime })
        model.startFailure = { [weak self] in self?.lastStartError }
        model.openLayouts = { [weak self] in self?.layoutsWindow.show() }
        model.hud = hud
        model.restoreFromJournal = { [context] in
            await Self.restoreFromJournal(context: context)
        }
        return model
    }()
    let identifier: DisplayIdentifier
    /// The Layouts window, built on first use; it reads the pane model and the running plugin.
    private(set) lazy var layoutsWindow: LayoutsWindowController = makeLayoutsWindow()

    private(set) lazy var editorWindow = GridEditorWindowController()
    /// The first activation of this process honours safe mode; a later one (the user switched the plugin on
    /// again, or pressed Try Again) clears it.
    private var launchActivationDone = false

    public convenience init(context: PluginContext) {
        self.init(
            context: context, hud: WindowsHUDPanel(clock: context.clock), activationCenter: .default, showsStrip: true,
            showsOverlay: true)
    }

    init(
        context: PluginContext, hud: any WindowsHUDPresenting, activationCenter: NotificationCenter,
        showsStrip: Bool = false, showsOverlay: Bool = false, layouts registry: LayoutRegistry = .standard
    ) {
        self.registry = registry
        identifier = DisplayIdentifier(clock: context.clock)
        let journal = JournalOwner.owner(for: context)
        self.journal = journal
        self.showsStrip = showsStrip
        self.showsOverlay = showsOverlay
        self.context = context
        self.settings = WindowsSettings(context.settings)
        self.hud = hud
        self.activationCenter = activationCenter
        hud.allowAccessibility = { [workspace = context.workspace] in
            guard let url = Self.accessibilitySettingsURL else { return }
            Task { try? await workspace.open(url) }
        }
        // What the launch recovery reported before this instance existed is shown now, and what it reports later.
        journal.reports.attach { [hud] state in hud.show(state) }
    }

    /// System Settings, Privacy & Security, Accessibility.
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    public var requiredPermissions: Set<Permission> { [.accessibility] }

    /// Throws when the window client is `unsupported`, so the host marks the plugin `failed` (spec: API
    /// Contracts), and in safe mode on the first start of a launch. Then starts the engine.
    public func activate() async throws {
        // The self-check calls Accessibility, which can block: the client runs it off the main actor.
        let availability = await context.windows.checkAvailability()
        if case .unsupported(let reason) = availability {
            lastStartError = .unsupported(reason: reason)
            throw StartError.unsupported(reason: reason)
        }
        if settings.safeMode {
            if !launchActivationDone {
                launchActivationDone = true
                lastStartError = .safeMode
                throw StartError.safeMode
            }
            settings.setSafeMode(false)
            settings.setParkedLaunches(0)
        }
        launchActivationDone = true
        lastStartError = nil
        guard runtime == nil else { return }
        let parts = WindowsComposition.parts(showsStrip: showsStrip, showsOverlay: showsOverlay)
        let runtime = WindowsRuntime(
            context: context, settings: settings, registry: registry, hud: hud, journal: journal,
            activationCenter: activationCenter,
            makeStrip: parts.makeStrip, makeDragController: parts.makeDragController)
        runtime.tearDownOverlay = parts.tearDownOverlay
        self.runtime = runtime
        runtime.onTrustGranted = { [weak self] in await self?.recheckAvailability() }
        do {
            try await runtime.start()
        } catch {
            // Only this attempt's own runtime is dropped: a deactivation that came first already took it.
            if self.runtime === runtime { self.runtime = nil }
            switch error {
            case let start as StartError: lastStartError = start
            case is CancellationError: break  // a stop or the host's budget ended it; nothing to report
            default: lastStartError = .failed(reason: String(describing: type(of: error)))
            }
            // `stop()` stops an engine only for a runtime that holds the journal lease: a start that gave up before
            // taking it has nothing to stop; one that was cancelled after taking it ends its engine and the lease here.
            await runtime.stop()
            throw error
        }
        #if DEBUG
        // QA only (`--qa-setting plugins.windows.qaOpenLayouts=true`): show the Layouts window without a click.
        if settings.qaOpenLayouts {
            layoutsWindow.activatesApp = false
            layoutsWindow.show()
        }
        #endif
    }

    /// Accessibility was granted: the self-check could not compare any window before, so it runs again. A mismatch
    /// stops the engine (every window is put back first) and the pane says Lintel needs an update.
    func recheckAvailability() async {
        let availability = await context.windows.checkAvailability()
        guard case .unsupported(let reason) = availability else { return }
        lastStartError = .unsupported(reason: reason)
        // Called from the runtime's own re-grant task: it cannot wait for itself.
        await deactivate(waitingForTrustTask: false)
        context.resultsChanged()
    }

    /// Puts every parked window back (waiting at most 5 s) and stops.
    public func deactivate() async {
        await deactivate(waitingForTrustTask: true)
    }

    private func deactivate(waitingForTrustTask: Bool) async {
        guard let runtime else { return }
        self.runtime = nil
        editorWindow.pluginSwitchedOff()
        // A layouts window with an editor sheet stays until the editor is answered.
        if !editorWindow.isOpen { layoutsWindow.close() }
        identifier.tearDown()
        await runtime.stop(waitingForTrustTask: waitingForTrustTask)
    }
}
