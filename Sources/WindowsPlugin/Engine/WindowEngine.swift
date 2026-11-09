import CoreGraphics
import Foundation
import LintelCore
import LintelKit
import os

/// Runs `EngineReducer` and hands its effects to an `EffectExecutor` (spec: Architecture, "WindowEngine is a
/// reducer plus effects").
///
/// Reducing and executing are decoupled. The reducer runs synchronously on the actor, so it never waits for an
/// app: every input that is queued is reduced at once, and the effects it returns go to lanes (one serial queue
/// per process, one for the journal and the stored state). A hung app therefore delays only the later work for
/// that app. Each finished frame change is fed back as an `.applied` input, and the reducer drops results whose
/// generation is no longer the newest for their window. The journal of parked windows is written first, and a
/// window is parked only after that write succeeded.
///
/// `send`, `submit` and `restoreAllWindows` return when the work their input caused has been executed and its
/// results reduced, or after `commandBudget` at the latest: a hung app can delay the completion of a user command
/// by at most that long, and its work then goes on in the background. After `stop()` they return at once.
///
/// Events from the client are coalesced and flushed by one serial flush loop, so inputs reach the reducer in the
/// order the events were read, and a flush never overlaps the next.
actor WindowEngine {
    private var state: EngineState
    private let client: any WindowClient
    private let store: StateStore
    private let time: TimeSource
    private let tick: Duration
    private let reporter: EngineReporter
    private let strategies: LayoutRegistry
    private let logger: Logger
    /// A bound on how long a command waits for slow apps (a real-time liveness bound, not engine time).
    private let commandBudget: Duration
    /// Whether windows may be moved at all: the plugin is enabled (the engine exists only then) and Accessibility
    /// is trusted (owner rule: nothing moves without Accessibility).
    private let canMove: @Sendable () -> Bool
    private var executor: EffectExecutor
    private var coalescer = EventCoalescer()
    private var flushTask: Task<Void, Never>?
    private var flushChain: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    /// Events are collected from the moment the engine subscribes but flushed only once the first snapshot has been
    /// reduced, so none overtakes it.
    private var flushEnabled = false
    private var stopped = false

    /// One queued input and what waits for it.
    private struct Pending {
        var input: EngineInput
        var waiter: (@Sendable () -> Void)?
        /// The batch whose result this input carries: it is not finished before what this input causes is.
        var parent: Int?
    }

    /// The work one reduction handed to the lanes.
    private struct Batch {
        var remaining = 0
        var waiters: [@Sendable () -> Void] = []
        var parents: [Int] = []
    }

    private var pending: [Pending] = []
    private var batches: [Int: Batch] = [:]
    private var nextBatch = 0
    private var inFlight = 0
    private var flushesRunning = 0
    private var quietWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        client: any WindowClient,
        store: StateStore,
        clock: any Clock<Duration> = ContinuousClock(),
        workspaceCount: Int = WindowsSettings.defaultWorkspaceCount,
        config: EngineConfig = EngineConfig(),
        tick: Duration = .milliseconds(30),
        commandBudget: Duration = .seconds(2),
        watchdog: Watchdog = Watchdog(),
        reporter: EngineReporter = EngineReporter(),
        strategies: LayoutRegistry = .standard,
        canMove: @escaping @Sendable () -> Bool = { true },
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "windows")
    ) {
        var state = EngineState(workspaceCount: workspaceCount)
        state.config = config
        self.state = state
        self.client = client
        self.store = store
        self.time = TimeSource(clock)
        self.tick = tick
        self.commandBudget = commandBudget
        self.reporter = reporter
        self.strategies = strategies
        self.canMove = canMove
        self.logger = logger
        executor = EffectExecutor(
            client: client, store: store, reporter: reporter, strategies: strategies, watchdog: watchdog,
            logger: logger)
    }

    // MARK: Lifecycle

    /// Subscribes to the client's events, loads the stored membership and takes the first snapshot. The
    /// subscription comes first, so a window that appears or goes while the snapshot is read is not lost: its
    /// event waits in the coalescer and is flushed after the snapshot.
    func start() async {
        stopped = false
        flushEnabled = false
        let events = await client.subscribe()
        pumpTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
        await store.load()
        let canJournal = await store.canJournal
        let stored = await store.state
        var inputs: [EngineInput] = [.journalAvailability(canJournal), .restoreLayouts(stored.layouts)]
        inputs.append(await snapshotInput())
        await submitInternal(inputs)
        flushEnabled = true
        if !coalescer.isEmpty { scheduleFlush() }
    }

    /// Puts every parked window back, waits for everything in flight and stops. Safe to call more than once. From
    /// the moment it is called no new input is accepted.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        pumpTask?.cancel()
        pumpTask = nil
        flushTask?.cancel()
        flushTask = nil
        // Events still waiting for the tick are dropped: the restore below needs none of them.
        _ = coalescer.drain()
        _ = await restoreWindows()
        await flushChain?.value
        await settle()
        await store.close()
    }

    /// Puts every parked window back (the engine's own and anything the journal still holds, such as windows
    /// that were on another Space), clears the journal as it goes and returns what happened. The engine then stays
    /// still until the next workspace command.
    func restoreAllWindows() async -> RecoveryReport {
        guard !stopped else { return RecoveryReport() }
        return await restoreWindows()
    }

    private func restoreWindows() async -> RecoveryReport {
        let before = Set(state.parked.keys)
        await submitInternal([.command(.restoreAll, now: time.now())], bounded: false)
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

    // MARK: Queries

    /// The slots the snap overlay offers while a window is dragged (empty when it must not appear).
    func dragDisplays(for id: WindowID) -> [DragDisplay] {
        EngineReducer.snapTargets(state, for: id, strategies: strategies)
    }

    func summary() -> WorkspaceSummary { EngineReducer.summary(of: state) }

    /// The windows the engine holds, with their cached title and workspace (the switcher reads this instead of
    /// scanning every app).
    func trackedWindows() -> [(id: WindowID, title: String, bundleID: String?, workspace: WorkspaceID?)] {
        state.windows.values.sorted { $0.id < $1.id }.map {
            ($0.id, $0.title, $0.bundleID, state.model.workspace(of: $0.id))
        }
    }

    func diagnostics() -> EngineDiagnostics { state.diagnostics }
    func parkedCount() -> Int { state.parked.count }

    /// Whether anything is parked: the engine's own windows or an entry still in the journal.
    func hasParkedWindows() async -> Bool {
        if !state.parked.isEmpty { return true }
        return !(await store.hidden.isEmpty)
    }

    #if DEBUG
    /// Reads any part of the state on the engine's actor (tests only).
    func inspect<T: Sendable>(_ read: @Sendable (EngineState) -> T) -> T { read(state) }
    #endif

    /// Restores journal entries of windows the engine does not hold (parked by an earlier run, on another Space
    /// then) whose window is on this Space now.
    private func restoreVisibleResidue() async {
        guard canMove() else { return }
        let report = await WindowRecovery.run(
            store: store, client: client, trusted: true, excluding: Set(state.parked.keys), logger: logger)
        if report.restored > 0 { reporter.restored(report) }
    }

    // MARK: Input

    func send(_ command: EngineCommand) async {
        await submit([.command(command, now: time.now())])
    }

    func update(config: EngineConfig) async {
        await submit([.configChanged(config), .command(.reload, now: time.now())])
    }

    /// Feeds inputs directly (tests; events go through `ingest`). Returns when what they caused has been
    /// executed, or after `commandBudget`; at once after `stop()`.
    func submit(_ inputs: [EngineInput]) async {
        guard !stopped else { return }
        await submitInternal(inputs)
    }

    private func submitInternal(_ inputs: [EngineInput], bounded: Bool = true) async {
        guard !inputs.isEmpty else { return }
        let finished = OneShot<Void>()
        for input in inputs.dropLast() { pending.append(Pending(input: input)) }
        pending.append(Pending(input: inputs[inputs.count - 1], waiter: { finished.set(()) }))
        reduceAndDispatch()
        if bounded {
            _ = await withDeadline(commandBudget, clock: ContinuousClock()) { await finished.wait() }
        } else {
            await finished.wait()
        }
    }

    private func enqueue(_ inputs: [EngineInput]) {
        guard !inputs.isEmpty, !stopped else { return }
        pending.append(contentsOf: inputs.map { Pending(input: $0) })
        reduceAndDispatch()
    }

    /// Waits until nothing is queued and nothing is running on the lanes (tests, tear-down).
    func waitForWork() async {
        if isQuiet { return }
        await withCheckedContinuation { quietWaiters.append($0) }
    }

    /// Waits until the engine has nothing queued, nothing running and no event waiting for a flush.
    func settle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isQuiet: Bool { pending.isEmpty && inFlight == 0 }

    private var isIdle: Bool {
        isQuiet && coalescer.isEmpty && flushTask == nil && flushesRunning == 0
    }

    private func resumeWaiters() {
        guard isQuiet else { return }
        let quiet = quietWaiters
        quietWaiters = []
        for waiter in quiet { waiter.resume() }
        guard isIdle else { return }
        let idle = idleWaiters
        idleWaiters = []
        for waiter in idle { waiter.resume() }
    }

    // MARK: Events

    /// Takes one event from the client; it is folded into the coalescer and flushed on the next tick.
    func ingest(_ event: WindowEvent) {
        guard !stopped else { return }
        coalescer.insert(event)
        if flushEnabled { scheduleFlush() }
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, time, tick] in
            do { try await time.sleep(tick) } catch { return }
            await self?.flushLoop()
        }
    }

    /// Flushes until the coalescer is empty. Only one flush loop exists at a time (`flushTask`).
    private func flushLoop() async {
        while !stopped, !coalescer.isEmpty { await flush(waiting: false) }
        flushTask = nil
        resumeWaiters()
    }

    /// Flushes the coalesced events now and waits for the work they cause (tests drive the engine with this).
    func flushEvents() async {
        await flush(waiting: true)
    }

    /// One flush, strictly after the previous one: the events are drained and read inside the chain, so inputs reach
    /// the reducer in the order the events were taken.
    private func flush(waiting: Bool) async {
        let previous = flushChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.drainAndSubmit()
        }
        flushChain = task
        await task.value
        if waiting {
            // Everything that was waiting for the tick has been flushed by hand: the tick has nothing left to do.
            if coalescer.isEmpty, !stopped {
                flushTask?.cancel()
                flushTask = nil
            }
            await waitForWork()
        }
    }

    private func drainAndSubmit() async {
        guard !stopped else { return }
        let events = coalescer.drain()
        guard !events.isEmpty else { return }
        flushesRunning += 1
        defer {
            flushesRunning -= 1
            resumeWaiters()
        }
        let inputs = await inputs(for: events)
        // Not waited for: a flush must never sit behind a hung app, or later events would queue behind it.
        guard !stopped else { return }
        enqueue(inputs)
    }

    /// Turns coalesced events into inputs, reading what they need from the client.
    private func inputs(for events: [WindowEvent]) async -> [EngineInput] {
        let moment = time.now()
        var inputs: [EngineInput] = []
        var infos: [WindowID: WindowInfo] = [:]
        for event in events {
            switch event {
            case .created(let id), .moved(let id), .resized(let id):
                if infos[id] == nil, let info = await client.window(id: id) { infos[id] = info }
            default:
                break
            }
        }
        for event in events {
            switch event {
            case .created(let id):
                if let info = infos[id] {
                    inputs.append(.windowAppeared(info, processStart: client.processStart(of: id.pid), now: moment))
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
                // A window that got the focus may have a new title: one single read keeps the cache fresh.
                if let id, state.windows[id] != nil, let info = await client.window(id: id) {
                    inputs.append(.windowAppeared(info, processStart: nil, now: moment))
                }
            case .appTerminated(let pid):
                for id in state.windows.keys where id.pid == pid { inputs.append(.windowGone(id, now: moment)) }
            case .appLaunched:
                break
            case .displaysChanged:
                inputs.append(.displaysChanged(await client.displays(), now: moment))
            case .spaceChanged, .resync:
                await restoreVisibleResidue()
                inputs.append(await snapshotInput())
            }
        }
        return inputs
    }

    private func snapshotInput() async -> EngineInput {
        let windows = await client.windows()
        let displays = await client.displays()
        let focused = await client.focusedWindow()
        var starts: [Int32: Double] = [:]
        for window in windows where starts[window.id.pid] == nil {
            if let start = client.processStart(of: window.id.pid) { starts[window.id.pid] = start }
        }
        return .snapshot(windows: windows, displays: displays, focused: focused, processStarts: starts, now: time.now())
    }

    // MARK: Reducing and dispatching

    /// Reduces everything queued, in order, and hands the effects to the executor. Synchronous: it never waits
    /// for an app, so it cannot be held up by one.
    private func reduceAndDispatch() {
        while !pending.isEmpty {
            let items = pending
            pending = []
            var effects: [EngineEffect] = []
            var batch = Batch()
            for item in items {
                let (next, produced) = EngineReducer.reduce(state, item.input, strategies: strategies)
                state = next
                effects.append(contentsOf: produced)
                if let waiter = item.waiter { batch.waiters.append(waiter) }
                if let parent = item.parent { batch.parents.append(parent) }
            }
            nextBatch += 1
            let id = nextBatch
            let dispatched = executor.dispatch(
                Self.coalesce(effects), batch: id, now: time.now(), trusted: canMove(), callbacks: callbacks)
            batch.remaining = dispatched.operations
            inFlight += dispatched.operations
            batches[id] = batch
            for input in dispatched.inputs { queue(input, parent: id) }
            closeIfFinished(id)
        }
        resumeWaiters()
    }

    private var callbacks: EffectExecutor.Callbacks {
        EffectExecutor.Callbacks(
            started: { [weak self] request in await self?.frameStarting(request) },
            isCurrent: { [weak self] request in await self?.isCurrent(request) ?? false },
            finished: { [weak self] batch, result in await self?.finished(batch: batch, result: result) })
    }

    /// A frame change is about to reach the app: its echo window starts now.
    private func frameStarting(_ request: FrameRequest) {
        pending.append(Pending(input: .frameStarted(request, now: time.now())))
        reduceAndDispatch()
    }

    /// Whether `request` is still the newest for its window (a window that is gone has no newest).
    private func isCurrent(_ request: FrameRequest) -> Bool {
        state.latest[request.id].map { $0 <= request.generation } ?? false
    }

    /// Called on the actor when one piece of work of `batch` finished, with the result to reduce, if any.
    private func finished(batch: Int, result: FrameResult?) {
        if let result { queue(.applied([result], now: time.now()), parent: batch) }
        reduceAndDispatch()
        inFlight -= 1
        decrement(batch)
        resumeWaiters()
    }

    /// Queues an input caused by a batch; that batch stays open until what the input causes has run.
    private func queue(_ input: EngineInput, parent: Int) {
        batches[parent]?.remaining += 1
        pending.append(Pending(input: input, parent: parent))
    }

    private func decrement(_ id: Int) {
        batches[id]?.remaining -= 1
        closeIfFinished(id)
    }

    private func closeIfFinished(_ id: Int) {
        guard let batch = batches[id], batch.remaining <= 0 else { return }
        batches[id] = nil
        for waiter in batch.waiters { waiter() }
        // The batches whose results caused this one were held open until now.
        for parent in batch.parents { decrement(parent) }
    }

    /// Keeps one frame change per window (the newest generation) and orders the effects: journal additions, frame
    /// changes, journal removals, everything else.
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
}
