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
/// `send` and `submit` return when the work their input caused has been executed and its results reduced, or after
/// `commandBudget` at the latest: a hung app can delay the completion of a user command by at most that long, and
/// its work then goes on in the background. `restoreAllWindows` is not bounded: its report counts what was really
/// put back, so it waits for the restore to run (the caller of `stop()` bounds that wait). After `stop()` they
/// return at once.
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
    private let translator: EventTranslator
    private let strategies: LayoutRegistry
    private let logger: Logger
    /// A bound on how long a command waits for slow apps (a real-time liveness bound, not engine time).
    private let commandBudget: Duration?
    private let clock: any Clock<Duration>
    private var nextWaiter: UInt64 = 0
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
    /// The retry that looks at the windows again while an app has not answered (`trackUnknown`).
    private var retryTask: Task<Void, Never>?
    /// How long after a snapshot that could not read an app the engine looks again (and again, until it can).
    static let unknownRetry: Duration = .seconds(5)
    /// The longest wait between two looks (the wait doubles from `unknownRetry` up to this).
    static let unknownRetryLimit: Duration = .seconds(60)
    private var retryDelay = WindowEngine.unknownRetry
    /// When the last flush started (engine time); a move is flushed at once only when none ran in the last tick.
    private var lastFlushAt = -Double.infinity

    /// One queued input and what waits for it.
    private struct Pending {
        var input: EngineInput
        var waiter: BatchLedger.Waiter?
        /// The batch whose result this input carries: it is not finished before what this input causes is.
        var parent: Int?
    }

    private var pending: [Pending] = []
    private var ledger = BatchLedger()
    /// An event passes three stages, each with one marker: waiting in the coalescer, scheduled (`flushTask`), being
    /// translated (`flushesRunning`). `isIdle` is true when no event is in any of them and no work is running;
    /// `isQuiet` only looks at the work. Two predicates because a test of the lanes must not wait for a tick.
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
        commandBudget: Duration? = .seconds(2),
        watchdog: Watchdog = Watchdog(),
        reporter: EngineReporter = EngineReporter(),
        strategies: LayoutRegistry,
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
        self.clock = clock
        self.reporter = reporter
        translator = EventTranslator(client: client)
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
        // An engine runs once: a `stop()` that came first (the runtime gave up on a start that hung) wins, so a
        // late start cannot revive it, subscribe to a stream nobody ends or move a window.
        guard !stopped else { return }
        flushEnabled = false
        let events = await client.subscribe()
        pumpTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
        guard !stopped else { return await abandonStart() }
        await store.load()
        guard !stopped else { return await abandonStart() }
        let canJournal = await store.canJournal
        let stored = await store.state
        var inputs: [EngineInput] = [.journalAvailability(canJournal), .restoreLayouts(stored.layouts)]
        inputs.append(await snapshotInput())
        guard !stopped else { return await abandonStart() }
        await submitInternal(inputs)
        flushEnabled = true
        if !coalescer.isEmpty { scheduleFlush() }
    }

    /// A `stop()` ran while `start()` was suspended: what `start()` created after that point is ended here.
    private func abandonStart() async {
        pumpTask?.cancel()
        // Awaited, like in `stop()`: the client's stream has really ended when `start()` returns.
        await pumpTask?.value
        pumpTask = nil
        flushTask?.cancel()
        flushTask = nil
    }

    /// Puts every parked window back, waits for everything in flight and stops. Safe to call more than once. From
    /// the moment it is called no new input is accepted.
    func stop() async {
        guard !stopped else { return }
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        pumpTask?.cancel()
        // The pump is awaited, so the client's stream has really ended when `stop()` returns and a restart's
        // `subscribe()` cannot be handed a stream that is still dying.
        await pumpTask?.value
        pumpTask = nil
        flushTask?.cancel()
        flushTask = nil
        // Events still waiting for the tick are dropped: the restore below needs none of them.
        _ = coalescer.drain()
        _ = await restoreWindows()
        await flushChain?.value
        await waitUntilIdle()
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

    #if DEBUG
    /// How many callers wait on batches that have not finished (a bound that fired leaves none).
    func waitingCallers() -> Int { ledger.waiterCount }
    #endif
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
        nextWaiter += 1
        let token = nextWaiter
        for input in inputs.dropLast() { pending.append(Pending(input: input)) }
        pending.append(
            Pending(input: inputs[inputs.count - 1], waiter: BatchLedger.Waiter(token: token) { finished.set(()) }))
        reduceAndDispatch()
        guard bounded, let budget = commandBudget else {
            await finished.wait()
            return
        }
        // The bound runs on the engine's own clock. A timer that fires first releases the wait and the ledger drops
        // the waiter, so a batch that never finishes keeps no task, no continuation and no closure of this call.
        let clock = clock
        let timer = Task {
            do { try await clock.sleep(for: budget) } catch { return }
            finished.set(())
        }
        await finished.wait()
        timer.cancel()
        ledger.removeWaiter(token)
    }

    private func enqueue(_ inputs: [EngineInput]) {
        guard !inputs.isEmpty, !stopped else { return }
        pending.append(contentsOf: inputs.map { Pending(input: $0) })
        reduceAndDispatch()
    }

    /// Waits until nothing is queued and nothing is running on the lanes.
    private func waitUntilQuiet() async {
        if isQuiet { return }
        await withCheckedContinuation { quietWaiters.append($0) }
    }

    /// Waits until the engine has nothing queued, nothing running and no event waiting for a flush.
    private func waitUntilIdle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    #if DEBUG
    // Test hooks: production code waits inside `stop()`; nothing else needs to know when the engine is quiet.
    func waitForWork() async { await waitUntilQuiet() }
    func settle() async { await waitUntilIdle() }
    #endif

    /// Nothing queued and no batch open (the ledger is the one count of work on the lanes).
    private var isQuiet: Bool { pending.isEmpty && ledger.isIdle }

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

    /// Takes one event from the client; it is folded into the coalescer and flushed on the next tick, except the
    /// first move of a window that may be starting a snap drag, which is flushed at once (the overlay has a 50 ms
    /// budget and the tick alone is 30 ms of it); the moves that follow are coalesced as usual.
    func ingest(_ event: WindowEvent) {
        guard !stopped else { return }
        #if DEBUG
        // A trace starts only for what could be a user's snap drag (the predicate the snap flow uses), never for a
        // window the engine or a script moved.
        if case .moved(let id) = event, LayoutPlanner(strategies: strategies).canStartSnapDrag(state, id) {
            DragTrace.begin()
        }
        DragTrace.mark("ingest")
        #endif
        coalescer.insert(event)
        guard flushEnabled else { return }
        if flushTask == nil, startsSnapDrag(event) {
            flushTask = Task { [weak self] in await self?.flushLoop() }
        } else {
            scheduleFlush()
        }
    }

    /// Whether `event` is a move of a window the engine manages on a workspace that offers snap targets: the one
    /// event whose latency matters to the user (the overlay follows it).
    private func startsSnapDrag(_ event: WindowEvent) -> Bool {
        let ticks = Double(tick.components.seconds) + Double(tick.components.attoseconds) / 1e18
        guard case .moved(let id) = event, time.now() - lastFlushAt >= ticks else { return false }
        return LayoutPlanner(strategies: strategies).canStartSnapDrag(state, id)
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

    #if DEBUG
    /// Flushes the coalesced events now and waits for the work they cause (tests drive the engine with this).
    func flushEvents() async {
        await flush(waiting: true)
    }
    #endif

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
                // A `settle()` that waited only for that tick has nothing left to wait for.
                resumeWaiters()
            }
            await waitUntilQuiet()
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
        #if DEBUG
        DragTrace.mark("flushStart")
        #endif
        let moment = time.now()
        lastFlushAt = moment
        let time = time
        let inputs = await translator.inputs(
            for: events, state: state, moment: moment, now: { time.now() },
            onSpaceChange: { [weak self] in await self?.restoreVisibleResidue() })
        #if DEBUG
        DragTrace.mark("read")
        #endif
        // Not waited for: a flush must never sit behind a hung app, or later events would queue behind it.
        guard !stopped else { return }
        enqueue(inputs)
    }

    /// While a process the engine holds windows of did not answer (`EngineState.unresponsive`: a park timed out, or a
    /// snapshot could not read it), what it left on screen is only *unknown*: the engine looks again after
    /// `unknownRetry`, then after twice as long each time up to `unknownRetryLimit`, until a read lists the windows or
    /// says they are gone. A process the engine holds no window of never arms it, so an app that is permanently
    /// unresponsive or has no Accessibility costs nothing.
    private func updateRetry() {
        let tracked = Set(state.windows.keys.map(\.pid))
        if state.unresponsive.isDisjoint(with: tracked) {
            retryTask?.cancel()
            retryTask = nil
            retryDelay = Self.unknownRetry
            return
        }
        guard retryTask == nil, !stopped else { return }
        let delay = retryDelay
        retryTask = Task { [weak self, time] in
            do { try await time.sleep(delay) } catch { return }
            await self?.retryUnknown()
        }
    }

    private func retryUnknown() {
        retryTask = nil
        retryDelay = min(retryDelay * 2, Self.unknownRetryLimit)
        ingest(.resync)
    }

    private func snapshotInput() async -> EngineInput {
        await translator.snapshot(now: time.now(), tracked: Set(state.windows.keys.map(\.pid)))
    }

    // MARK: Reducing and dispatching

    /// Reduces everything queued, in order, and hands the effects to the executor. Synchronous: it never waits
    /// for an app, so it cannot be held up by one.
    private func reduceAndDispatch() {
        while !pending.isEmpty {
            let items = pending
            pending = []
            var effects: [EngineEffect] = []
            var waiters: [BatchLedger.Waiter] = []
            var parents: [Int] = []
            for item in items {
                let (next, produced) = EngineReducer.reduce(state, item.input, strategies: strategies)
                state = next
                effects.append(contentsOf: produced)
                if let waiter = item.waiter { waiters.append(waiter) }
                if let parent = item.parent { parents.append(parent) }
            }
            // The id is the ledger's next one: the executor tags its pieces of work with it.
            let dispatched = executor.dispatch(
                EffectExecutor.coalesce(effects), batch: ledger.peekNextID, now: time.now(), trusted: canMove(),
                callbacks: callbacks)
            let id = ledger.open(operations: dispatched.operations, waiters: waiters, parents: parents)
            for input in dispatched.inputs { queue(input, parent: id) }
            ledger.closeIfFinished(id)
        }
        updateRetry()
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
        ledger.finish(batch)
        resumeWaiters()
    }

    /// Queues an input caused by a batch; that batch stays open until what the input causes has run.
    private func queue(_ input: EngineInput, parent: Int) {
        ledger.hold(parent)
        pending.append(Pending(input: input, parent: parent))
    }
}
