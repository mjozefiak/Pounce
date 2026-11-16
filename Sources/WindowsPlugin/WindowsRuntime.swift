import Foundation
import LintelCore
import LintelKit
import LintelUI
import Synchronization
import os

/// Everything the plugin runs while it is active: the engine over the context's window client, the journal
/// store, the Accessibility tracker and the HUD. It exists only between `activate()` and `deactivate()`, so a
/// plugin that is off holds no store, no observer and no task.
@MainActor
final class WindowsRuntime: WindowSwitching {
    /// How long a disable or a quit waits for windows to be put back; what is left stays in the journal for the
    /// next launch (spec: Architecture, "Recovery runs outside the plugin lifecycle").
    static let stopBudget: Duration = .seconds(5)
    /// How long a start waits for an earlier run that is still putting windows back before it gives up
    /// (`WindowsPlugin.StartError.stillStopping`).
    static let startBudget: Duration = .seconds(5)
    /// How long *Restore all windows* waits for apps that do not answer before it reports what is still parked.
    static let restoreBudget: Duration = .seconds(5)

    let context: PluginContext
    let settings: WindowsSettings
    /// The journal owner of the storage folder: the engine and every recovery pass share its one store.
    let journal: JournalOwner
    var store: StateStore { journal.store }
    /// Which layout each workspace uses on each display (`assignments.json`).
    let assignments: AssignmentStore
    /// The user's layout library and the layout slots (`layouts.json`).
    let layouts: LayoutRepository
    let engine: WindowEngine
    let trust: AccessibilityTrust
    let hud: any WindowsHUDPresenting
    private let gate: AccessibilityGate
    /// The one registry of layout strategies: the engine, the configuration, the commands and the pane use it.
    let registry: LayoutRegistry
    private(set) lazy var layoutCommands = LayoutCommands(
        context: context, settings: settings, registry: registry, assignments: assignments, layouts: layouts,
        engine: engine,
        gate: gate, currentWorkspace: { [weak self] in self?.lastSummary?.current },
        apply: { [weak self] in await self?.applySettings() })
    /// The menu bar strip; `nil` until `start()` when it is on, and in tests that pass `makeStrip: nil`.
    var strip: WorkspaceStripController?
    let makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)?
    /// Drag-to-snap: `nil` in tests that pass no factory (the overlay needs a display).
    var dragController: ZoneDragController?
    let makeDragController: (@MainActor (WindowsRuntime) -> ZoneDragController)?
    /// Releases the overlay panels when the runtime stops.
    var tearDownOverlay: @MainActor () -> Void = {}
    var lastSummary: WorkspaceSummary?
    /// The engine's reports, handled on the main actor in the order it produced them.
    let reports: ReportPump
    /// The restore after a re-grant of Accessibility, while it runs.
    var trustTask: Task<Void, Never>?
    /// What the strip's clicks start, in the order they happened.
    let actions = OrderedActions()
    /// The journal lease of the engine while it runs (`JournalOwner`).
    var lease: UInt64?
    /// The engine configuration as last sent (cached: it is rebuilt only when a setting or the library changes).
    private(set) var engineConfig: EngineConfig
    /// Called when Accessibility is granted, before windows are restored (the plugin re-runs the self-check).
    var onTrustGranted: () async -> Void = {}
    /// Where the runtime is in its one life (`WindowsRuntime+Lifecycle.swift`).
    var phase = Phase.idle
    /// The newest problem the engine reported, for the Settings banner.
    var engineBanner: EngineBanner?
    /// Windows put back by *Restore all windows*, a re-grant and a Space change in this session (diagnostics).
    var recoveredWindows = 0
    var activationObserver: AppActivationObserver?

    init(
        context: PluginContext, settings: WindowsSettings, registry: LayoutRegistry, hud: any WindowsHUDPresenting,
        journal: JournalOwner,
        activationCenter: NotificationCenter = .default, tick: Duration = .milliseconds(30),
        makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)? = nil,
        makeDragController: (@MainActor (WindowsRuntime) -> ZoneDragController)? = nil
    ) {
        self.makeStrip = makeStrip
        self.makeDragController = makeDragController
        self.context = context
        self.settings = settings
        self.registry = registry
        self.hud = hud
        self.journal = journal
        let store = journal.store
        assignments = AssignmentStore(directory: context.storageDirectory, logger: context.logger)
        layouts = LayoutRepository(directory: context.storageDirectory, logger: context.logger)
        let trust = AccessibilityTrust(reader: context.permissions, clock: context.clock)
        self.trust = trust
        gate = AccessibilityGate(trust: trust, hud: hud)
        let flag = trust.flag
        let pump = ReportPump { _ in }
        reports = pump
        engineConfig = EngineConfig(settings: settings, registry: registry)
        engine = WindowEngine(
            client: context.windows, store: store, clock: context.clock, workspaceCount: settings.workspaceCount,
            config: engineConfig, tick: tick, reporter: pump.reporter, strategies: registry,
            canMove: { flag.isTrusted },
            logger: context.logger)
        self.activationCenter = activationCenter
        reports.handler = { [weak self] report in self?.handle(report) }
    }

    private func handle(_ report: EngineReport) {
        switch report {
        case .hud(let workspace, let count):
            if settings.showHUD { hud.show(.workspace(number: workspace.rawValue, windowCount: count)) }
        case .summary(let summary):
            summaryChanged(summary)
        case .banner(let banner):
            engineBanner = banner
            context.resultsChanged()
        case .windowMoved(let id, let frame):
            #if DEBUG
            DragTrace.mark("reportedOnMain")
            #endif
            dragController?.windowMoved(id, frame: frame)
        case .restored(let report):
            hud.show(WindowsHUDState(report: report))
        }
    }

    /// The engine reports every change of the workspaces; the strip redraws.
    private func summaryChanged(_ summary: WorkspaceSummary) {
        lastSummary = summary
        strip?.update(stripBoxes())
        showSnapHintIfNeeded()
    }

    /// The first time a Zones layout is on screen, once ever: how to snap by dragging. Only with Accessibility,
    /// because without it nothing can be snapped.
    func showSnapHintIfNeeded() {
        guard !settings.snapHintShown, trust.isTrusted, let summary = lastSummary else { return }
        let layout = engineConfig.layout
        guard
            summary.visible.values.contains(where: {
                registry[layout.resolved(for: $0).kind]?.snapping != nil
            })
        else { return }
        settings.setSnapHintShown(true)
        hud.show(.snapHint)
    }

    /// A drag released over a target: the engine sends the target's own command for the window (the strategy that
    /// offered it decides what it does), behind the same Accessibility gate as every move.
    func snap(_ window: WindowID, to zone: DragZone) async {
        guard trust.refresh() else { return }
        await engine.send(.layout(zone.command, on: window))
    }

    func stripBoxes() -> [StripBox] {
        StripModel.boxes(
            summary: lastSummary ?? WorkspaceSummary(current: nil, visible: [:], counts: [:]),
            workspaceCount: settings.workspaceCount, occupiedOnly: settings.stripMode == .occupied)
    }

    /// Shows or hides the strip as the setting says.
    func applyStrip() {
        guard let makeStrip else { return }
        if settings.stripEnabled {
            let strip = strip ?? makeStrip(self)
            self.strip = strip
            strip.install()
            strip.update(stripBoxes())
        } else {
            strip?.remove()
            strip = nil
        }
    }

    let activationCenter: NotificationCenter

    #if DEBUG
    /// Waits until the engine has nothing queued or running and everything it reported has been handled here
    /// (tests only).
    func settle() async {
        await actions.waitUntilEmpty()
        await trustTask?.value
        await engine.settle()
        await reports.waitUntilHandled()
    }
    #endif

    /// Runs an engine command, but only while Accessibility is trusted. Without it nothing moves and the HUD says
    /// why, with a button that opens the setting.
    func run(_ command: EngineCommand, purpose: AccessibilityPurpose) async {
        await gate.run(purpose) { await engine.send(command) }
    }

    /// Rebuilds the engine configuration from the settings, the assignments and the library, and sends it.
    func refreshConfig() async {
        engineConfig = EngineConfig(
            settings: settings, registry: registry, assignments: await assignments.table,
            library: await layouts.library)
        await engine.update(config: engineConfig)
    }

    func applySettings() async {
        await refreshConfig()
        await engine.send(.setWorkspaceCount(settings.workspaceCount))
        applyStrip()
        showSnapHintIfNeeded()
    }

    /// Accessibility came back: windows parked before it was revoked are restored at once, which is the only safe
    /// thing to do after a gap in which the user may have moved anything.
    func trustChanged(_ trusted: Bool) {
        guard trusted else { return }
        trustTask = Task { [engine, hud] in
            await self.onTrustGranted()
            guard !Task.isCancelled else { return }
            let report = await engine.restoreAllWindows()
            self.recoveredWindows += report.restored
            if !report.isEmpty {
                hud.show(WindowsHUDState(report: report))
            } else if let current = self.lastSummary?.current {
                // Nothing was parked, so there is nothing to protect from a second hide: let the engine arrange
                // the windows again (the restore left it still, and without Accessibility nothing was tiled).
                await engine.send(.showWorkspace(current))
            }
        }
    }
}
