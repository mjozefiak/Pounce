import CoreGraphics
import Foundation
import LintelKit
import os

/// Where the engine reports what the user should see. Called from the engine's actor; each closure must be quick
/// and hop to the main actor itself.
struct EngineOutputs: Sendable {
    var hud: @Sendable (_ workspace: WorkspaceID, _ windowCount: Int) -> Void = { _, _ in }
    var summary: @Sendable (WorkspaceSummary) -> Void = { _ in }
    var banner: @Sendable (EngineBanner) -> Void = { _ in }
    /// A managed window of a Zones workspace was moved by the user (or an app): the snap overlay's detector samples
    /// the pointer.
    var windowMoved: @Sendable (WindowID) -> Void = { _ in }
    /// Windows came back without a command asking for it (a Space change showed journal entries again).
    var restored: @Sendable (RecoveryReport) -> Void = { _ in }
}

/// Runs `EngineReducer` and carries out its effects against a `WindowClient` and the `StateStore` (spec:
/// Architecture, "WindowEngine is a reducer plus effects").
///
/// Inputs are processed one batch at a time: everything that arrived while the previous batch was running is
/// reduced in order, the resulting frame changes are coalesced per window (the newest generation wins) and then
/// executed, in parallel across processes and in order within one process, so a slow app delays only itself.
/// The journal of parked windows is written first, and a window is parked only after that write succeeded.
actor WindowEngine {
    private(set) var state: EngineState
    private let client: any WindowClient
    private let store: StateStore
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Double
    private let tick: Duration
    private let outputs: EngineOutputs
    private let logger: Logger
    /// Whether windows may be moved at all: the plugin is enabled (the engine exists only then) and Accessibility
    /// is trusted. When it answers `false` every frame change fails with `.notTrusted` before it reaches the
    /// client, no window is focused and nothing is parked (owner rule: nothing moves without Accessibility).
    private let canMove: @Sendable () -> Bool
    private var watchdog: Watchdog
    private var coalescer = EventCoalescer()
    private var pending: [EngineInput] = []
    private var isProcessing = false
    private var settleWaiters: [CheckedContinuation<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    /// Frame changes executed so far (tests and diagnostics).
    private(set) var frameChangeCount = 0

    init(
        client: any WindowClient,
        store: StateStore,
        clock: any Clock<Duration> = ContinuousClock(),
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        workspaceCount: Int = WindowsSettings.defaultWorkspaceCount,
        config: EngineConfig = EngineConfig(),
        tick: Duration = .milliseconds(30),
        watchdog: Watchdog = Watchdog(),
        outputs: EngineOutputs = EngineOutputs(),
        canMove: @escaping @Sendable () -> Bool = { true },
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "windows")
    ) {
        var state = EngineState(workspaceCount: workspaceCount)
        state.config = config
        self.state = state
        self.client = client
        self.store = store
        self.clock = clock
        self.now = now
        self.tick = tick
        self.watchdog = watchdog
        self.outputs = outputs
        self.canMove = canMove
        self.logger = logger
    }

    // MARK: Lifecycle

    /// Loads the stored membership, takes the first snapshot and starts listening to the client's events.
    func start() async {
        await store.load()
        let canJournal = await store.canJournal
        pending.append(.journalAvailability(canJournal))
        pending.append(.restoreTiling(await store.state.tiling))
        pending.append(.restoreZones(await store.state.zones))
        pending.append(await snapshotInput())
        await run()
        pumpTask = Task { [client] in
            for await event in client.events {
                self.ingest(event)
            }
        }
    }

    /// Puts every parked window back, then stops. Safe to call more than once.
    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        flushTask?.cancel()
        flushTask = nil
        _ = await restoreAllWindows()
        await store.close()
    }

    /// Puts every parked window back (the engine's own and anything the journal still holds, such as windows
    /// that were on another Space), clears the journal as it goes and returns what happened. The engine then stays
    /// still until the next workspace command.
    func restoreAllWindows() async -> RecoveryReport {
        let before = Set(state.parked.keys)
        pending.append(.command(.restoreAll, now: now()))
        await run()
        var report = RecoveryReport()
        let stillParked = Set(state.parked.keys)
        report.restored = before.subtracting(stillParked).count
        report.failed = stillParked.count
        let trusted = canMove()
        let residue = await WindowRecovery.run(
            store: store, client: client, trusted: trusted, excluding: stillParked, logger: logger)
        report.restored += residue.restored
        report.onAnotherSpace += residue.onAnotherSpace
        report.failed += residue.failed
        report.needsAccessibility = !trusted && (!before.isEmpty || residue.needsAccessibility)
        return report
    }

    /// The zones the snap overlay offers while a window is dragged (empty when it must not appear).
    func dragDisplays(for id: WindowID) -> [DragDisplay] { state.dragDisplays(for: id) }

    /// What the window switcher needs: the workspace of every window the engine holds and the counts.
    func switcherState() -> (membership: [WindowID: WorkspaceID], summary: WorkspaceSummary) {
        var membership: [WindowID: WorkspaceID] = [:]
        for id in state.windows.keys { membership[id] = state.model.workspace(of: id) }
        return (membership, EngineReducer.summary(of: state))
    }

    /// Whether anything is parked: the engine's own windows or an entry still in the journal.
    func hasParkedWindows() async -> Bool {
        if !state.parked.isEmpty { return true }
        return !(await store.hidden.isEmpty)
    }

    /// Restores journal entries of windows the engine does not hold (parked by an earlier run, on another Space
    /// then) whose window is on this Space now.
    private func restoreVisibleResidue() async {
        guard canMove() else { return }
        let report = await WindowRecovery.run(
            store: store, client: client, trusted: true, excluding: Set(state.parked.keys), logger: logger)
        if report.restored > 0 { outputs.restored(report) }
    }

    func send(_ command: EngineCommand) async {
        pending.append(.command(command, now: now()))
        await run()
    }

    func update(config: EngineConfig) async {
        pending.append(.configChanged(config))
        pending.append(.command(.reload, now: now()))
        await run()
    }

    /// Feeds inputs directly (tests; the event pump goes through `ingest`).
    func submit(_ inputs: [EngineInput]) async {
        pending.append(contentsOf: inputs)
        await run()
    }

    /// Waits until the engine has nothing queued and nothing running.
    func settle() async {
        if !isProcessing, pending.isEmpty, coalescer.isEmpty, flushTask == nil { return }
        await withCheckedContinuation { settleWaiters.append($0) }
    }

    // MARK: Events

    /// Takes one event from the client; it is folded into the coalescer and handled on the next tick.
    func ingest(_ event: WindowEvent) {
        coalescer.insert(event)
        guard flushTask == nil else { return }
        flushTask = Task { [clock, tick] in
            do { try await clock.sleep(for: tick) } catch { return }
            await self.flushEvents()
        }
    }

    /// Turns the coalesced events into inputs, reading what they need from the client once.
    func flushEvents() async {
        flushTask = nil
        let events = coalescer.drain()
        guard !events.isEmpty else {
            resumeWaitersIfIdle()
            return
        }
        let moment = now()
        var inputs: [EngineInput] = []
        let needsWindows = events.contains {
            switch $0 {
            case .created, .moved, .resized: true
            default: false
            }
        }
        let infos: [WindowID: WindowInfo] =
            needsWindows
            ? Dictionary(await client.windows().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            : [:]
        for event in events {
            switch event {
            case .created(let id):
                if let info = infos[id] {
                    inputs.append(
                        .windowAppeared(info, processStart: client.processStart(of: id.pid), now: moment))
                }
            case .destroyed(let id):
                inputs.append(.windowGone(id, now: moment))
            case .moved(let id), .resized(let id):
                if let info = infos[id] {
                    if state.windows[id] != nil, EngineReducer.isManaged(info, config: state.config) {
                        inputs.append(.windowMoved(id, frame: info.frame, now: moment))
                    } else {
                        // A window the engine does not hold (yet) or no longer manages (it went fullscreen or
                        // came back from it): look at it as if it had just appeared.
                        inputs.append(
                            .windowAppeared(info, processStart: client.processStart(of: id.pid), now: moment))
                    }
                }
            case .focused(let id):
                inputs.append(.windowFocused(id, now: moment))
            case .appTerminated(let pid):
                for id in state.windows.keys where id.pid == pid { inputs.append(.windowGone(id, now: moment)) }
            case .appLaunched:
                break
            case .displaysChanged:
                inputs.append(.displaysChanged(await client.displays(), now: moment))
            case .spaceChanged:
                await restoreVisibleResidue()
                inputs.append(await snapshotInput())
            }
        }
        pending.append(contentsOf: inputs)
        await run()
        resumeWaitersIfIdle()
    }

    private func snapshotInput() async -> EngineInput {
        let windows = await client.windows()
        let displays = await client.displays()
        let focused = await client.focusedWindow()
        var starts: [Int32: Double] = [:]
        for window in windows where starts[window.id.pid] == nil {
            if let start = client.processStart(of: window.id.pid) { starts[window.id.pid] = start }
        }
        return .snapshot(windows: windows, displays: displays, focused: focused, processStarts: starts, now: now())
    }

    // MARK: Processing

    /// Runs batches until nothing is queued. A second caller while one runs only enqueues: the running loop
    /// picks its inputs up in the next batch.
    private func run() async {
        guard !isProcessing else { return }
        isProcessing = true
        while !pending.isEmpty {
            let batch = pending
            pending = []
            var effects: [EngineEffect] = []
            for input in batch {
                let (next, produced) = EngineReducer.reduce(state, input)
                state = next
                effects.append(contentsOf: produced)
            }
            let results = await execute(Self.coalesce(effects))
            if !results.isEmpty { pending.insert(.applied(results, now: now()), at: 0) }
        }
        isProcessing = false
        resumeWaitersIfIdle()
    }

    private func resumeWaitersIfIdle() {
        guard !isProcessing, pending.isEmpty, coalescer.isEmpty, flushTask == nil else { return }
        let waiters = settleWaiters
        settleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Keeps one frame change per window (the newest generation) and orders the effects: journal additions,
    /// frame changes, journal removals, everything else.
    static func coalesce(_ effects: [EngineEffect]) -> [EngineEffect] {
        var journalAdds: [HiddenEntry] = []
        var requests: [WindowID: FrameRequest] = [:]
        var requestOrder: [WindowID] = []
        var removals = Set<WindowID>()
        var rest: [EngineEffect] = []
        for effect in effects {
            switch effect {
            case .journalPark(let entries):
                journalAdds.append(contentsOf: entries)
            case .setFrame(let request):
                if let existing = requests[request.id], existing.generation > request.generation { continue }
                if requests[request.id] == nil { requestOrder.append(request.id) }
                requests[request.id] = request
            case .journalRemove(let ids):
                removals.formUnion(ids)
            default:
                rest.append(effect)
            }
        }
        var result: [EngineEffect] = []
        if !journalAdds.isEmpty { result.append(.journalPark(journalAdds)) }
        result.append(contentsOf: requestOrder.compactMap { requests[$0].map(EngineEffect.setFrame) })
        if !removals.isEmpty { result.append(.journalRemove(removals)) }
        result.append(contentsOf: rest)
        return result
    }

    // MARK: Effects

    private func execute(_ effects: [EngineEffect]) async -> [FrameResult] {
        guard canMove() else { return await executeWithoutAccessibility(effects) }
        var blocked = Set<WindowID>()
        var requests: [FrameRequest] = []
        var removals = Set<WindowID>()
        var others: [EngineEffect] = []
        for effect in effects {
            switch effect {
            case .journalPark(let entries):
                do {
                    try await store.addHidden(entries)
                } catch {
                    blocked.formUnion(entries.map(\.windowID))
                }
            case .setFrame(let request): requests.append(request)
            case .journalRemove(let ids): removals.formUnion(ids)
            default: others.append(effect)
            }
        }
        let results = await apply(requests, blocked: blocked)
        if !removals.isEmpty {
            do { try await store.removeHidden(removals) } catch {
                logger.error("Cannot clear the journal after a restore")
            }
        }
        for effect in others { await perform(effect) }
        return results
    }

    /// Nothing is moved, focused or journaled: every frame change fails as `.notTrusted`, which the reducer
    /// answers by keeping a parked window parked and a window that was meant to be parked where it is.
    private func executeWithoutAccessibility(_ effects: [EngineEffect]) async -> [FrameResult] {
        var results: [FrameResult] = []
        var removals = Set<WindowID>()
        for effect in effects {
            switch effect {
            case .setFrame(let request):
                results.append(FrameResult(request: request, outcome: .failed(.notTrusted)))
            case .journalRemove(let ids):
                removals.formUnion(ids)
            case .journalPark, .focus, .userMovedWindow:
                break
            default:
                await perform(effect)
            }
        }
        if !removals.isEmpty { try? await store.removeHidden(removals) }
        return results
    }

    /// Executes frame changes in parallel across processes and in order within one. The watchdog counts each
    /// change; when it trips, the rest of the batch is dropped and the engine is told to restore everything.
    private func apply(_ requests: [FrameRequest], blocked: Set<WindowID>) async -> [FrameResult] {
        guard !requests.isEmpty else { return [] }
        var allowed: [FrameRequest] = []
        var results: [FrameResult] = []
        var tripped = false
        for request in requests {
            if request.purpose == .park, blocked.contains(request.id) {
                results.append(FrameResult(request: request, outcome: .blocked))
                continue
            }
            // Restoring is the way out of a fight, so it is never counted: the watchdog must not stop itself.
            if request.purpose != .restore, watchdog.record(now: now()) {
                tripped = true
                break
            }
            allowed.append(request)
        }
        frameChangeCount += allowed.count
        let byProcess = Dictionary(grouping: allowed, by: \.id.pid)
        let client = client
        let executed = await withTaskGroup(of: [FrameResult].self) { group in
            for (_, group_) in byProcess {
                group.addTask {
                    var done: [FrameResult] = []
                    for request in group_ {
                        do throws(WindowClientError) {
                            let actual = try await client.setFrame(request.frame, for: request.id)
                            done.append(FrameResult(request: request, outcome: .applied(actual)))
                        } catch {
                            done.append(FrameResult(request: request, outcome: .failed(error)))
                        }
                    }
                    return done
                }
            }
            var all: [FrameResult] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
        // A stable order, so the reducer sees the same sequence whatever the processes' timing.
        results.append(
            contentsOf: executed.sorted {
                ($0.request.id, $0.request.generation) < ($1.request.id, $1.request.generation)
            })
        if tripped {
            watchdog.reset()
            pending.append(.watchdogTripped(now: now()))
        }
        return results
    }

    private func perform(_ effect: EngineEffect) async {
        switch effect {
        case .focus(let id):
            try? await client.focus(id)
        case .saveOrder(let order):
            await store.setOrder(order)
        case .saveTiling(let tiling):
            await store.setTiling(tiling)
        case .saveZones(let zones):
            await store.setZones(zones)
        case .userMovedWindow(let id):
            outputs.windowMoved(id)
        case .hud(let workspace, let count):
            outputs.hud(workspace, count)
        case .summaryChanged(let summary):
            outputs.summary(summary)
        case .banner(let banner):
            outputs.banner(banner)
        case .journalPark, .journalRemove, .setFrame:
            break
        }
    }
}
