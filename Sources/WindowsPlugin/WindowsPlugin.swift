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
    private let identifier = DisplayIdentifier()
    /// The Layouts window, built on first use; it reads the pane model and the running plugin.
    private(set) lazy var layoutsWindow: LayoutsWindowController = makeLayoutsWindow()

    private func makeLayoutsWindow() -> LayoutsWindowController {
        LayoutsWindowController(makeModel: { [unowned self] in
            LayoutsModel(
                pane: paneModel, displays: { [client = context.windows] in await client.displays() },
                identify: { [identifier] display in identifier.show(display) },
                openEditor: { [unowned self] layout, isNew, onSaved in
                    openEditor(layout: layout, isNew: isNew, parent: layoutsWindow.window, onSaved: onSaved)
                },
                files: AppKitLayoutFiles())
        })
    }
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
        var makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)?
        if showsStrip {
            makeStrip = { runtime in
                WorkspaceStripController(
                    select: { number in
                        guard let workspace = WorkspaceID(number) else { return }
                        Task { await runtime.goToWorkspace(workspace) }
                    },
                    restoreAll: { Task { await runtime.restoreAllWindows() } })
            }
        }
        var makeDrag: (@MainActor (WindowsRuntime) -> ZoneDragController)?
        var overlay: ZoneOverlayPanels?
        if showsOverlay {
            let panels = ZoneOverlayPanels()
            overlay = panels
            makeDrag = { runtime in
                ZoneDragController(
                    sampler: SystemPointerSampler(), presenter: panels, ticker: TimerDragTicker(),
                    targets: { [engine = runtime.engine] id in await engine.dragDisplays(for: id) },
                    snap: { [weak runtime] id, zone in await runtime?.snap(id, to: zone) })
            }
        }
        let runtime = WindowsRuntime(
            context: context, settings: settings, hud: hud, journal: journal, activationCenter: activationCenter,
            makeStrip: makeStrip,
            makeDragController: makeDrag)
        runtime.tearDownOverlay = { overlay?.tearDown() }
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

    /// Opens the grid editor on a layout (a copy of a stock one, a user's own, or a new one). Needs the running
    /// plugin: the library lives in its runtime.
    func openEditor(
        layout: GridLayout, isNew: Bool, parent: NSWindow? = nil, onSaved: @escaping (GridLayout) -> Void = { _ in }
    ) {
        guard let repository = runtime?.layouts else { return }
        editorWindow.show(parent: parent) { [client = context.windows] preview, close in
            GridEditorModel(
                layout: layout, isNew: isNew, repository: repository, displays: { await client.displays() },
                preview: preview,
                announce: { text in
                    AccessibilityNotification.Announcement(text).post()
                },
                onSaved: onSaved,
                onClose: { [weak self] in
                    close()
                    // The plugin was switched off while the editor held changes: the Layouts window was left
                    // open for the editor's sheet and goes with it.
                    if let self, runtime == nil { layoutsWindow.close() }
                })
        }
    }

    /// A double-clicked `.lintellayouts` file: the Layouts window opens and shows what importing it would do
    /// (never adds anything by itself). A plugin that is off only says so.
    public func handleOpenedFile(_ url: URL) async -> Bool {
        guard url.pathExtension.lowercased() == LayoutFileType.fileExtension else { return false }
        layoutsWindow.show()
        guard let model = layoutsWindow.model else { return true }
        await model.refresh()
        model.loadImport(from: url)
        return true
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

    /// *Restore all windows*: ends with the restore HUD. Without a running engine it works from the journal.
    func restoreAllWindows() async {
        if let runtime {
            await runtime.restoreAllWindows()
            return
        }
        let report = await Self.restoreFromJournal(context: context, journals: journals)
        hud.show(WindowsHUDState(report: report))
    }

    /// "Erase Data": puts every window back first; the host then deletes `Plugins/windows/`.
    public func eraseData() async throws {
        await deactivate()
        let report = await Self.restoreFromJournal(context: context, journals: journals)
        if report.remaining > 0 {
            context.logger.notice("Erasing window data with \(report.remaining, privacy: .public) windows not restored")
        }
    }

    // MARK: Recovery

    /// Runs once per launch for every registered plugin, enabled or not (spec: Architecture, "Recovery runs
    /// outside the plugin lifecycle"): reads the journal and puts every parked window back. `.deferred` while
    /// Accessibility is not trusted, so the journal stays and the host tries again on app activation.
    public nonisolated static func recoverAtLaunch(context: PluginContext) async -> RecoveryOutcome {
        let journal = JournalRegistry.shared.owner(
            for: context.storageDirectory, clock: context.clock, logger: context.logger)
        return await recover(context: context, hud: { await journal.present($0) })
    }

    /// `recoverAtLaunch` with the registry and the HUD injected (tests). `isLaunch` is `nil` in the app: the
    /// journal owner counts the first pass of this process as the launch.
    nonisolated static func recover(
        context: PluginContext, isLaunch: Bool? = nil, journals: JournalRegistry = .shared,
        hud: @Sendable (WindowsHUDState) async -> Void
    ) async -> RecoveryOutcome {
        let journal = journals.owner(for: context.storageDirectory, clock: context.clock, logger: context.logger)
        let first: Bool
        if let isLaunch { first = isLaunch } else { first = await journal.claimLaunch() }
        // A running engine owns its journal: the windows parked in it are parked on purpose.
        let pass = await journal.exclusive { store in await restore(context: context, store: store) }
        let report: RecoveryReport
        switch pass {
        case .engineRunning: return .done
        case .engineStopping: return .deferred
        case .ran(let done): report = done
        }
        let settings = WindowsSettings(context.settings)
        if first, !report.readOnly {
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

    /// One exclusive pass over the journal in `context.storageDirectory`; empty while an engine owns it.
    nonisolated static func restoreFromJournal(
        context: PluginContext, journals: JournalRegistry = .shared
    ) async -> RecoveryReport {
        let journal = journals.owner(for: context.storageDirectory, clock: context.clock, logger: context.logger)
        if case .ran(let report) = await journal.exclusive({ store in await restore(context: context, store: store) }) {
            return report
        }
        return RecoveryReport()
    }

    private nonisolated static func restore(context: PluginContext, store: StateStore) async -> RecoveryReport {
        await store.load()
        guard await !store.hidden.isEmpty else { return RecoveryReport() }
        let trusted = await MainActor.run { context.permissions.status(of: .accessibility) == .granted }
        let report = await WindowRecovery.run(
            store: store, client: context.windows, trusted: trusted, logger: context.logger)
        await store.close()
        return report
    }
}
