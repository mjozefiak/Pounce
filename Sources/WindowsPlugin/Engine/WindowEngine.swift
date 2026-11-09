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
    var windowMoved: @Sendable (WindowID, CGRect) -> Void = { _, _ in }
    /// Windows came back without a command asking for it (a Space change showed journal entries again).
    var restored: @Sendable (RecoveryReport) -> Void = { _ in }
}

/// Runs `EngineReducer` and carries out its effects against a `WindowClient` and the `StateStore` (spec:
/// Architecture, "WindowEngine is a reducer plus effects").
///
/// Reducing and executing are decoupled. The reducer runs synchronously on the actor, so it never waits for an
/// app: every input that is queued is reduced at once, and the effects it returns are handed to *lanes*, one
/// serial queue per process (frame changes and focus) and one for the journal and the stored state. A hung app
/// therefore delays only the later work for that app; other apps, other workspace switches and the journal go
/// on. Each finished frame change is fed back as an `.applied` input, and the reducer drops results whose
/// generation is no longer the newest for their window. The journal of parked windows is written first, and a
/// window is parked only after that write succeeded.
///
/// `send`, `submit` and `restoreAllWindows` return when the work their input caused has been executed and its
/// results reduced, not when the input was merely queued.
actor WindowEngine {
    private var state: EngineState
    private let client: any WindowClient
    private let store: StateStore
    private let time: TimeSource
    private let tick: Duration
    private let outputs: EngineOutputs
    private let strategies: LayoutRegistry
    private let logger: Logger
    /// Whether windows may be moved at all: the plugin is enabled (the engine exists only then) and Accessibility
    /// is trusted. When it answers `false` every frame change fails with `.notTrusted` before it reaches the
    /// client, no window is focused and nothing is parked (owner rule: nothing moves without Accessibility).
    private let canMove: @Sendable () -> Bool
    private var watchdog: Watchdog
    private var coalescer = EventCoalescer()
    private var flushTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?

    /// One queued input and what waits for it.
    private struct Pending {
        var input: EngineInput
        var waiter: CheckedContinuation<Void, Never>?
        /// The batch whose result this input carries: it is not finished before what this input causes is.
        var parent: Int?
    }

    /// The work one reduction handed to the lanes.
    private struct Batch {
        var remaining = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var parents: [Int] = []
    }

    private enum LaneKey: Hashable {
        case process(Int32)
        case store
    }

    private var pending: [Pending] = []
    private var batches: [Int: Batch] = [:]
    private var nextBatch = 0
    private var lanes: [LaneKey: Task<Void, Never>] = [:]
    private var inFlight = 0
    private var flushesRunning = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Frame changes executed so far (tests and diagnostics).
    private(set) var frameChangeCount = 0

    init(
        client: any WindowClient,
        store: StateStore,
        clock: any Clock<Duration> = ContinuousClock(),
        workspaceCount: Int = WindowsSettings.defaultWorkspaceCount,
        config: EngineConfig = EngineConfig(),
        tick: Duration = .milliseconds(30),
        watchdog: Watchdog = Watchdog(),
        outputs: EngineOutputs = EngineOutputs(),
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
        self.watchdog = watchdog
        self.outputs = outputs
        self.strategies = strategies
        self.canMove = canMove
        self.logger = logger
    }

    // MARK: Lifecycle

    /// Loads the stored membership, takes the first snapshot and starts listening to the client's events.
    func start() async {
        await store.load()
        let canJournal = await store.canJournal
        let stored = await store.state
        var inputs: [EngineInput] = [.journalAvailability(canJournal), .restoreLayouts(stored.layouts)]
        inputs.append(await snapshotInput())
        await submit(inputs)
        pumpTask = Task { [weak self, client] in
            for await event in client.events {
                guard let self else { return }
                await self.ingest(event)
            }
        }
    }

    /// Puts every parked window back, waits for everything in flight and stops. Safe to call more than once.
    func stop() async {
        pumpTask?.cancel()
        pumpTask = nil
        flushTask?.cancel()
        flushTask = nil
        _ = await restoreAllWindows()
        await settle()
        await store.close()
    }

    /// Puts every parked window back (the engine's own and anything the journal still holds, such as windows
    /// that were on another Space), clears the journal as it goes and returns what happened. The engine then stays
    /// still until the next workspace command.
    func restoreAllWindows() async -> RecoveryReport {
        let before = Set(state.parked.keys)
        await submit([.command(.restoreAll, now: time.now())])
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

    /// The zones the snap overlay offers while a window is dragged (empty when it must not appear).
    func dragDisplays(for id: WindowID) -> [DragDisplay] {
        EngineReducer.snapTargets(state, for: id, strategies: strategies)
    }

    /// What the window switcher needs: the workspace of every window the engine holds and the counts.
    func switcherState() -> (membership: [WindowID: WorkspaceID], summary: WorkspaceSummary) {
        var membership: [WindowID: WorkspaceID] = [:]
        for id in state.windows.keys { membership[id] = state.model.workspace(of: id) }
        return (membership, EngineReducer.summary(of: state))
    }

    /// The windows the engine holds, with their workspace and the app's bundle id (the search source reads this
    /// instead of scanning every app).
    func trackedWindows() -> [(id: WindowID, title: String, bundleID: String?, workspace: WorkspaceID?)] {
        state.windows.values.sorted { $0.id < $1.id }.map {
            ($0.id, $0.title, $0.bundleID, state.model.workspace(of: $0.id))
        }
    }

    func diagnostics() -> EngineDiagnostics { state.diagnostics }
    func parkedCount() -> Int { state.parked.count }

    /// Reads any part of the state on the engine's actor (tests).
    func inspect<T: Sendable>(_ read: @Sendable (EngineState) -> T) -> T { read(state) }

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

    // MARK: Input

    func send(_ command: EngineCommand) async {
        await submit([.command(command, now: time.now())])
    }

    func update(config: EngineConfig) async {
        await submit([.configChanged(config), .command(.reload, now: time.now())])
    }

    /// Feeds inputs directly (tests; the event pump goes through `ingest`). Returns when what they caused has
    /// been executed.
    func submit(_ inputs: [EngineInput]) async {
        guard !inputs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            for input in inputs.dropLast() { pending.append(Pending(input: input)) }
            pending.append(Pending(input: inputs[inputs.count - 1], waiter: continuation))
            reduceAndDispatch()
        }
    }

    private func enqueue(_ inputs: [EngineInput]) {
        guard !inputs.isEmpty else { return }
        pending.append(contentsOf: inputs.map { Pending(input: $0) })
        reduceAndDispatch()
    }

    /// Waits until the engine has nothing queued and nothing running.
    func settle() async {
        if isIdle { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private var isIdle: Bool {
        pending.isEmpty && inFlight == 0 && coalescer.isEmpty && flushTask == nil && flushesRunning == 0
    }

    private func resumeIdleWaiters() {
        guard isIdle else { return }
        lanes = [:]
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    // MARK: Events

    /// Takes one event from the client; it is folded into the coalescer and handled on the next tick.
    func ingest(_ event: WindowEvent) {
        coalescer.insert(event)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, time, tick] in
            do { try await time.sleep(tick) } catch { return }
            await self?.flushEvents()
        }
    }

    /// Turns the coalesced events into inputs, reading what they need from the client once.
    func flushEvents() async {
        flushTask = nil
        let events = coalescer.drain()
        guard !events.isEmpty else {
            resumeIdleWaiters()
            return
        }
        flushesRunning += 1
        defer {
            flushesRunning -= 1
            resumeIdleWaiters()
        }
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
            case .spaceChanged:
                await restoreVisibleResidue()
                inputs.append(await snapshotInput())
            }
        }
        await submit(inputs)
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

    /// Reduces everything queued, in order, and hands the effects to the lanes. Synchronous: it never waits for
    /// an app, so it cannot be held up by one.
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
            batches[id] = batch
            dispatch(Self.coalesce(effects), batch: id)
            closeIfFinished(id)
        }
        resumeIdleWaiters()
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

    // MARK: Lanes

    /// Runs `work` after everything queued before it on the same lane, and counts it as in flight for `batch`.
    @discardableResult
    private func enqueue<T: Sendable>(
        on key: LaneKey, batch: Int, _ work: @escaping @Sendable () async -> T
    ) -> Task<T, Never> {
        inFlight += 1
        batches[batch]?.remaining += 1
        let previous = lanes[key]
        let task = Task<T, Never> {
            await previous?.value
            return await work()
        }
        lanes[key] = Task { _ = await task.value }
        Task { [weak self] in
            let value = await task.value
            await self?.finished(batch: batch, result: value as? FrameResult)
        }
        return task
    }

    /// Called on the actor when one piece of work of `batch` finished, with the result to reduce, if any.
    private func finished(batch: Int, result: FrameResult?) {
        if let result { queue(.applied([result], now: time.now()), parent: batch) }
        reduceAndDispatch()
        inFlight -= 1
        decrement(batch)
        resumeIdleWaiters()
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
        for waiter in batch.waiters { waiter.resume() }
        // The batches whose results caused this one were held open until now.
        for parent in batch.parents { decrement(parent) }
    }

    // MARK: Effects

    private func dispatch(_ effects: [EngineEffect], batch: Int) {
        // A batch that was caused by results waits for the batches those results cause.
        let trusted = canMove()
        var journalEntries: [HiddenEntry] = []
        var requests: [FrameRequest] = []
        var removals = Set<WindowID>()
        var others: [EngineEffect] = []
        for effect in effects {
            switch effect {
            case .journalPark(let entries): journalEntries.append(contentsOf: entries)
            case .setFrame(let request): requests.append(request)
            case .journalRemove(let ids): removals.formUnion(ids)
            default: others.append(effect)
            }
        }
        guard trusted else {
            // Nothing is moved, focused or journaled: every frame change fails as `.notTrusted`, which the reducer
            // answers by keeping a parked window parked and a window that was meant to be parked where it is.
            let failed = requests.map { FrameResult(request: $0, outcome: .failed(.notTrusted)) }
            if !failed.isEmpty { queue(.applied(failed, now: time.now()), parent: batch) }
            if !removals.isEmpty { removeFromJournal(removals, batch: batch) }
            for effect in others {
                switch effect {
                case .focus, .userMovedWindow: break
                default: perform(effect, batch: batch)
                }
            }
            return
        }
        let store = store
        var journal: Task<Set<WindowID>, Never>?
        if !journalEntries.isEmpty {
            let entries = journalEntries
            journal = enqueue(on: .store, batch: batch) {
                do {
                    try await store.addHidden(entries)
                    return []
                } catch {
                    return Set(entries.map(\.windowID))
                }
            }
        }
        executeFrames(requests, journal: journal, batch: batch)
        if !removals.isEmpty { removeFromJournal(removals, batch: batch) }
        for effect in others { perform(effect, batch: batch) }
    }

    private func removeFromJournal(_ ids: Set<WindowID>, batch: Int) {
        let store = store
        let logger = logger
        enqueue(on: .store, batch: batch) {
            do { try await store.removeHidden(ids) } catch { logger.error("Cannot clear the journal") }
        }
    }

    /// Frame changes go to the lane of their process: in order within one process, in parallel across them. The
    /// watchdog counts each change; when it trips, the rest of the batch is dropped and the engine is told to
    /// restore everything.
    private func executeFrames(_ requests: [FrameRequest], journal: Task<Set<WindowID>, Never>?, batch: Int) {
        var tripped = false
        for request in requests {
            // Restoring is the way out of a fight, so it is never counted: the watchdog must not stop itself.
            if request.purpose != .restore, watchdog.record(now: time.now()) {
                tripped = true
                break
            }
            frameChangeCount += 1
            let client = client
            enqueue(on: .process(request.id.pid), batch: batch) { [weak self] () -> FrameResult? in
                if request.purpose == .park, let journal, await journal.value.contains(request.id) {
                    return FrameResult(request: request, outcome: .blocked)
                }
                // A newer request for this window was reduced while this one waited its turn: it is dropped.
                if let self, await !self.isCurrent(request) { return nil }
                do throws(WindowClientError) {
                    let actual = try await client.setFrame(request.frame, for: request.id)
                    return FrameResult(request: request, outcome: .applied(actual))
                } catch {
                    return FrameResult(request: request, outcome: .failed(error))
                }
            }
        }
        if tripped {
            watchdog.reset()
            queue(.watchdogTripped(now: time.now()), parent: batch)
        }
    }

    /// Whether `request` is still the newest for its window (a window that is gone has no newest).
    private func isCurrent(_ request: FrameRequest) -> Bool {
        state.latest[request.id].map { $0 <= request.generation } ?? false
    }

    private func perform(_ effect: EngineEffect, batch: Int) {
        let store = store
        switch effect {
        case .focus(let id):
            let client = client
            enqueue(on: .process(id.pid), batch: batch) { try? await client.focus(id) }
        case .saveOrder(let order):
            enqueue(on: .store, batch: batch) { await store.setOrder(order) }
        case .saveLayouts(let layouts):
            let encoded = strategies.encode(layouts)
            enqueue(on: .store, batch: batch) { await store.setLayouts(encoded) }
        case .userMovedWindow(let id, let frame):
            outputs.windowMoved(id, frame)
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
