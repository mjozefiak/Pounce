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
    private let configBuilder = EngineConfigBuilder()
    private(set) lazy var layoutCommands = LayoutCommands(
        context: context, settings: settings, assignments: assignments, layouts: layouts, engine: engine,
        gate: gate, currentWorkspace: { [weak self] in self?.lastSummary?.current },
        apply: { [weak self] in await self?.applySettings() })
    /// The menu bar strip; `nil` until `start()` when it is on, and in tests that pass `makeStrip: nil`.
    private(set) var strip: WorkspaceStripController?
    private let makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)?
    /// Drag-to-snap: `nil` in tests that pass no factory (the overlay needs a display).
    private(set) var dragController: ZoneDragController?
    private let makeDragController: (@MainActor (WindowsRuntime) -> ZoneDragController)?
    /// Releases the overlay panels when the runtime stops.
    var tearDownOverlay: @MainActor () -> Void = {}
    private var lastSummary: WorkspaceSummary?
    /// The engine's reports, handled on the main actor in the order it produced them.
    private let reports: ReportPump
    /// The restore after a re-grant of Accessibility, while it runs.
    private var trustTask: Task<Void, Never>?
    /// What the strip's clicks start, in the order they happened.
    let actions = OrderedActions()
    /// The journal lease of the engine while it runs (`JournalOwner`).
    private var lease: UInt64?
    /// The engine configuration as last sent (cached: it is rebuilt only when a setting or the library changes).
    private(set) var engineConfig: EngineConfig
    /// Called when Accessibility is granted, before windows are restored (the plugin re-runs the self-check).
    var onTrustGranted: () async -> Void = {}
    /// The newest problem the engine reported, for the Settings banner.
    private(set) var engineBanner: EngineBanner?
    /// Windows put back by *Restore all windows*, a re-grant and a Space change in this session (diagnostics).
    private(set) var recoveredWindows = 0
    private var activationObserver: AppActivationObserver?

    init(
        context: PluginContext, settings: WindowsSettings, hud: any WindowsHUDPresenting, journal: JournalOwner,
        activationCenter: NotificationCenter = .default, tick: Duration = .milliseconds(30),
        makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)? = nil,
        makeDragController: (@MainActor (WindowsRuntime) -> ZoneDragController)? = nil
    ) {
        self.makeStrip = makeStrip
        self.makeDragController = makeDragController
        self.context = context
        self.settings = settings
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
        engineConfig = configBuilder.build(settings)
        engine = WindowEngine(
            client: context.windows, store: store, clock: context.clock, workspaceCount: settings.workspaceCount,
            config: engineConfig, tick: tick, reporter: pump.reporter, canMove: { flag.isTrusted },
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
        guard summary.visible.values.contains(where: { layout.resolved(for: $0).kind == .zones }) else { return }
        settings.setSnapHintShown(true)
        hud.show(.snapHint)
    }

    /// A drag released over a zone: the engine moves the window, behind the same Accessibility gate as every
    /// move.
    func snap(_ window: WindowID, to zone: DragZone) async {
        guard trust.refresh() else { return }
        await engine.send(.snapToZone(window, zone: zone.zoneID, displayKey: zone.displayKey))
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

    private let activationCenter: NotificationCenter

    func start() async {
        trust.refresh()
        trust.onChange = { [weak self] trusted in self?.trustChanged(trusted) }
        let engine = engine
        trust.startPolling { await engine.hasParkedWindows() }
        activationObserver = AppActivationObserver(center: activationCenter) { [weak self] in
            self?.trust.refresh()
        }
        lease = await journal.beginEngine()
        await assignments.load()
        await layouts.load()
        await refreshConfig()
        await engine.start()
        applyStrip()
        if dragController == nil { dragController = makeDragController?(self) }
    }

    /// Waits until the engine has nothing queued or running and everything it reported has been handled here (tests
    /// and tear-down).
    func settle() async {
        await actions.waitUntilEmpty()
        await trustTask?.value
        await engine.settle()
        await reports.waitUntilHandled()
    }

    /// Puts the windows back and stops, waiting at most `stopBudget`.
    /// - Parameter waitingForTrustTask: `false` when the caller is that task itself (a failed self-check after a
    ///   re-grant stops the runtime from inside it).
    func stop(waitingForTrustTask: Bool = true) async {
        activationObserver?.stop()
        activationObserver = nil
        trust.stop()
        dragController?.cancel()
        dragController = nil
        tearDownOverlay()
        strip?.remove()
        strip = nil
        let engine = engine
        let journal = journal
        trustTask?.cancel()
        if waitingForTrustTask { await trustTask?.value }
        trustTask = nil
        await actions.waitUntilEmpty()
        reports.finish()
        let lease = lease
        if let lease { await journal.engineStopping(lease) }
        // The journal goes back to recovery only once the engine has really stopped, even when this wait gives
        // up first: a recovery pass must never run beside an engine that still moves windows.
        _ = await withDeadline(Self.stopBudget, clock: context.clock) {
            await engine.stop()
            if let lease { await journal.endEngine(lease) }
        }
    }

    /// Runs an engine command, but only while Accessibility is trusted. Without it nothing moves and the HUD says
    /// why, with a button that opens the setting.
    func run(_ command: EngineCommand, purpose: AccessibilityPurpose) async {
        await gate.run(purpose) { await engine.send(command) }
    }

    /// *Restore all windows*: always ends with the restore HUD.
    func restoreAllWindows() async {
        trust.refresh()
        let report = await engine.restoreAllWindows()
        recoveredWindows += report.restored
        hud.show(WindowsHUDState(report: report))
    }

    /// *Reset state*: puts every window back first, then forgets the stored state.
    func resetState() async {
        await restoreAllWindows()
        do { try await store.reset() } catch { context.logger.error("Cannot reset state.json") }
        // The layouts the user chose per workspace and display are part of the state that is forgotten.
        do { try await assignments.reset() } catch { context.logger.error("Cannot reset assignments.json") }
        await applySettings()
    }

    /// Clears the engine's frozen state (after the watchdog) by showing the current workspace again.
    func startAgain() async {
        engineBanner = nil
        if let target = lastSummary?.current ?? WorkspaceID.all(count: 1).first {
            await run(.showWorkspace(target), purpose: .switching)
        }
        context.resultsChanged()
    }

    func diagnosticsText() async -> String {
        let diagnostics = await engine.diagnostics()
        return WindowsDiagnostics.report(
            diagnostics, recoveredWindows: recoveredWindows, parkedWindows: await engine.parkedCount(),
            workspaceCount: settings.workspaceCount, accessibilityTrusted: trust.isTrusted)
    }

    /// Rebuilds the engine configuration from the settings, the assignments and the library, and sends it.
    private func refreshConfig() async {
        engineConfig = configBuilder.build(
            settings, assignments: await assignments.table, library: await layouts.library)
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
    private func trustChanged(_ trusted: Bool) {
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
