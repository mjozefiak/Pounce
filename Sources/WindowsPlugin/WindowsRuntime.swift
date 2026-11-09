import Foundation
import LintelKit
import LintelUI
import Synchronization
import os

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
    /// The menu bar strip; `nil` until `start()` when it is on, and in tests that pass `makeStrip: nil`.
    private(set) var strip: WorkspaceStripController?
    private let makeStrip: (@MainActor (WindowsRuntime) -> WorkspaceStripController)?
    /// Drag-to-snap: `nil` in tests that pass no factory (the overlay needs a display).
    private(set) var dragController: ZoneDragController?
    private let makeDragController: (@MainActor (WindowsRuntime) -> ZoneDragController)?
    /// Releases the overlay panels when the runtime stops.
    var tearDownOverlay: @MainActor () -> Void = {}
    private var lastSummary: WorkspaceSummary?
    private let summaryRelay: SummaryRelay
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
        let flag = trust.flag
        let relay = SummaryRelay()
        summaryRelay = relay
        engine = WindowEngine(
            client: context.windows, store: store, clock: context.clock, workspaceCount: settings.workspaceCount,
            config: Self.config(settings), tick: tick,
            outputs: EngineOutputs(
                hud: { workspace, count in
                    guard settings.workspaceHUD else { return }
                    Task { @MainActor in hud.show(.workspace(number: workspace.rawValue, windowCount: count)) }
                },
                summary: { summary in Task { @MainActor in relay.handler(summary) } },
                banner: { banner in Task { @MainActor in relay.bannerHandler(banner) } },
                windowMoved: { id, frame in Task { @MainActor in relay.dragHandler(id, frame) } },
                restored: { report in
                    Task { @MainActor in hud.show(WindowsHUDState(report: report)) }
                }),
            canMove: { flag.isTrusted }, logger: context.logger)
        self.activationCenter = activationCenter
        relay.handler = { [weak self] summary in self?.summaryChanged(summary) }
        relay.dragHandler = { [weak self] id, frame in self?.dragController?.windowMoved(id, frame: frame) }
        relay.bannerHandler = { [weak self] banner in
            self?.engineBanner = banner
            self?.context.resultsChanged()
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
        let layout = Self.config(settings).layout
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

    static func config(
        _ settings: WindowsSettings, assignments: AssignmentTable = AssignmentTable(),
        library: LayoutLibrary = .stock
    ) -> EngineConfig {
        var config = EngineConfig()
        config.followFocus = settings.followFocus
        config.floatingBundleIDs = Set(settings.floatingApps)
        config.layout = LayoutConfig(
            defaultKind: settings.defaultKind, innerGap: settings.innerGap, outerGap: settings.outerGap,
            rootOrientation: .horizontal, overrides: settings.workspaceOverrides.byWorkspace)
        config.zones = ZonesConfig(
            assignments: assignments, library: library,
            defaultLandscape: settings.defaultZoneLayout(for: .landscape),
            defaultPortrait: settings.defaultZoneLayout(for: .portrait))
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
        await journal.beginEngine()
        await assignments.load()
        await layouts.load()
        await engine.update(
            config: Self.config(settings, assignments: await assignments.table, library: await layouts.library))
        await engine.start()
        applyStrip()
        if dragController == nil { dragController = makeDragController?(self) }
    }

    /// Puts the windows back and stops, waiting at most `stopBudget`.
    func stop() async {
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
        await journal.engineStopping()
        // The journal goes back to recovery only once the engine has really stopped, even when this wait gives
        // up first: a recovery pass must never run beside an engine that still moves windows.
        _ = await TimeBound.run(budget: Self.stopBudget, clock: context.clock) {
            await engine.stop()
            await journal.endEngine()
        }
    }

    /// Runs an engine command, but only while Accessibility is trusted. Without it nothing moves and the HUD says
    /// why, with a button that opens the setting.
    func run(_ command: EngineCommand, purpose: AccessibilityPurpose) async {
        guard trust.refresh() else {
            hud.show(.accessibilityNeeded(purpose))
            return
        }
        await engine.send(command)
    }

    /// *Toggle layout*: cycles the current workspace through Auto-tile, Zones and Free by writing its layout kind
    /// override (every kind's state is kept, so cycling is lossless: the engine keeps the tree and the zone
    /// placement while another kind is active); a kind equal to the default clears the override. Does nothing when the stored
    /// overrides come from a newer version (they are never overwritten).
    func toggleLayout() async {
        guard trust.refresh() else {
            hud.show(.accessibilityNeeded(.moving))
            return
        }
        guard let workspace = lastSummary?.current else { return }
        var overrides = settings.workspaceOverrides
        guard !overrides.isReadOnly else { return }
        let current = overrides.byWorkspace[workspace]?.kind ?? settings.defaultKind
        let next = Self.nextKind(after: current)
        var entry = overrides.byWorkspace[workspace] ?? WorkspaceOverride()
        entry.kind = next == settings.defaultKind ? nil : next
        overrides.byWorkspace[workspace] = entry.isEmpty ? nil : entry
        settings.setWorkspaceOverrides(overrides)
        await applySettings()
        context.resultsChanged()
    }

    /// A layout slot command: the layout bound to the slot becomes the layout of the current workspace on the
    /// display of the focused window. An unbound slot does nothing. Behind the same Accessibility gate as every
    /// move, because the windows are placed again.
    func applyLayoutSlot(_ number: Int) async {
        guard let layoutID = await layouts.slots[number] else { return }
        await useLayout(layoutID)
    }

    /// *Next zone layout*: the layout after the one in effect, over the stock templates and then the user's.
    func nextLayout() async {
        guard let cell = await currentCell() else { return }
        let library = await layouts.library
        let config = Self.config(settings, assignments: await assignments.table, library: library).zones
        let displays = await context.windows.displays()
        let keyed = DisplayKeys.keys(for: displays)
        let orientation = displays.first { keyed.keys[$0.id] == cell.displayKey }?.orientation ?? .landscape
        let current = config.resolve(workspace: cell.workspace, displayKey: cell.displayKey, orientation: orientation)
        guard let next = library.next(after: current.layout.id) else { return }
        await useLayout(next)
    }

    private func currentCell() async -> (workspace: WorkspaceID, displayKey: String)? {
        let summary = await engine.switcherState().1
        guard let workspace = summary.current, let display = summary.focusedDisplay else { return nil }
        return (workspace, display)
    }

    private func useLayout(_ layoutID: String) async {
        guard trust.refresh() else {
            hud.show(.accessibilityNeeded(.moving))
            return
        }
        guard let cell = await currentCell() else { return }
        do {
            try await assignments.set(layoutID, workspace: cell.workspace, displayKey: cell.displayKey)
        } catch {
            context.logger.error("Cannot write assignments.json")
            return
        }
        await applySettings()
        context.resultsChanged()
    }

    /// Auto-tile, then Zones, then Free, then Auto-tile again.
    static func nextKind(after kind: LayoutKind) -> LayoutKind {
        switch kind {
        case .tiling: .zones
        case .zones: .free
        case .free: .tiling
        }
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

    func applySettings() async {
        await engine.update(
            config: Self.config(settings, assignments: await assignments.table, library: await layouts.library))
        await engine.send(.setWorkspaceCount(settings.workspaceCount))
        applyStrip()
        showSnapHintIfNeeded()
    }

    /// Accessibility came back: windows parked before it was revoked are restored at once, which is the only safe
    /// thing to do after a gap in which the user may have moved anything.
    private func trustChanged(_ trusted: Bool) {
        guard trusted else { return }
        Task { [engine, hud] in
            await self.onTrustGranted()
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

/// The window switcher over a running plugin.
extension WindowsRuntime: WindowSwitching {
    func snapshot() async -> SwitcherSnapshot {
        let (membership, summary) = await engine.switcherState()
        let live = trust.isTrusted ? await context.windows.windows() : []
        let windows =
            live
            .filter { membership[$0.id] != nil }
            .map {
                SwitcherWindow(id: $0.id, title: $0.title, bundleID: $0.bundleID, workspace: membership[$0.id] ?? nil)
            }
        let workspaces = WorkspaceID.all(count: settings.workspaceCount).map {
            (workspace: $0, windowCount: summary.counts[$0] ?? 0)
        }
        return SwitcherSnapshot(workspaces: workspaces, windows: windows)
    }

    func goToWorkspace(_ workspace: WorkspaceID) async { await run(.showWorkspace(workspace), purpose: .switching) }
    func goToWindow(_ id: WindowID) async { await run(.goToWindow(id), purpose: .switching) }
    func bringHere(_ id: WindowID) async { await run(.bringWindowHere(id), purpose: .moving) }
}

/// What the switcher uses while the plugin is not running: nothing.
struct InactiveSwitcher: WindowSwitching {
    func snapshot() async -> SwitcherSnapshot { SwitcherSnapshot(workspaces: [], windows: []) }
    func goToWorkspace(_ workspace: WorkspaceID) async {}
    func goToWindow(_ id: WindowID) async {}
    func bringHere(_ id: WindowID) async {}
}

/// Carries the engine's summary to the main actor once the runtime exists.
@MainActor
final class SummaryRelay {
    var handler: @MainActor (WorkspaceSummary) -> Void = { _ in }
    var bannerHandler: @MainActor (EngineBanner) -> Void = { _ in }
    var dragHandler: @MainActor (WindowID, CGRect) -> Void = { _, _ in }
}
