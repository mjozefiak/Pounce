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
    }

    let context: PluginContext
    let settings: WindowsSettings
    let hud: any WindowsHUDPresenting
    private let activationCenter: NotificationCenter
    let journals: JournalRegistry
    let journal: JournalOwner
    /// Whether the plugin shows the menu bar strip when it is on. Tests leave it off: a status item needs a display.
    private let showsStrip: Bool
    /// Whether the plugin builds the snap overlay (a panel per display). Tests leave it off, like the strip.
    private let showsOverlay: Bool
    private(set) var runtime: WindowsRuntime?
    private(set) var lastStartError: StartError?
    /// Built on first use; creating it reads settings only.
    private(set) lazy var paneModel: WindowsSettingsModel = {
        let model = WindowsSettingsModel(context: context, settings: settings, runtime: { [unowned self] in runtime })
        model.startFailure = { [unowned self] in lastStartError }
        model.openLayouts = { [unowned self] in layoutsWindow.show() }
        model.hud = hud
        model.restoreFromJournal = { [unowned self] in
            await Self.restoreFromJournal(context: context, journals: journals)
        }
        return model
    }()
    let identifier = DisplayIdentifier()
    /// The Layouts window, built on first use; it reads the pane model and the running plugin.
    private(set) lazy var layoutsWindow: LayoutsWindowController = makeLayoutsWindow()

    private(set) lazy var editorWindow = GridEditorWindowController()
    /// The first activation of this process honours safe mode; a later one (the user switched the plugin on
    /// again, or pressed Try Again) clears it.
    private var launchActivationDone = false

    public convenience init(context: PluginContext) {
        self.init(
            context: context, hud: WindowsHUDPanel(), activationCenter: .default, showsStrip: true,
            showsOverlay: true)
    }

    init(
        context: PluginContext, hud: any WindowsHUDPresenting, activationCenter: NotificationCenter,
        showsStrip: Bool = false, showsOverlay: Bool = false, journals: JournalRegistry = .shared
    ) {
        self.journals = journals
        let journal = journals.owner(for: context.storageDirectory, clock: context.clock, logger: context.logger)
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
        Task { [hud] in await journal.setSink { state in await MainActor.run { hud.show(state) } } }
    }

    /// System Settings, Privacy & Security, Accessibility.
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    public var requiredPermissions: Set<Permission> { [.accessibility] }

    /// Throws when the window client is `unsupported`, so the host marks the plugin `failed` (spec: API
    /// Contracts), and in safe mode on the first start of a launch. Then starts the engine.
    public func activate() async throws {
        // The self-check calls Accessibility, which can block: never on the main actor.
        let client = context.windows
        let availability = await Task.detached { client.availability }.value
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
            context: context, settings: settings, hud: hud, journal: journal, activationCenter: activationCenter,
            makeStrip: parts.makeStrip, makeDragController: parts.makeDragController)
        runtime.tearDownOverlay = parts.tearDownOverlay
        self.runtime = runtime
        runtime.onTrustGranted = { [weak self] in await self?.recheckAvailability() }
        await runtime.start()
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
        let client = context.windows
        let availability = await Task.detached { client.availability }.value
        guard case .unsupported(let reason) = availability else { return }
        lastStartError = .unsupported(reason: reason)
        await deactivate()
        context.resultsChanged()
    }

    /// Puts every parked window back (waiting at most 5 s) and stops.
    public func deactivate() async {
        guard let runtime else { return }
        self.runtime = nil
        editorWindow.pluginSwitchedOff()
        // A layouts window with an editor sheet stays until the editor is answered.
        if !editorWindow.isOpen { layoutsWindow.close() }
        identifier.tearDown()
        await runtime.stop()
    }
}
