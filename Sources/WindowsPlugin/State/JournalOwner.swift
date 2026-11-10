import Foundation
import LintelKit
import Synchronization
import os

/// The one owner of `Plugins/windows/state.json` for a storage folder: it holds the only `StateStore` (the single
/// writer of the file) and decides who may use it. Either the running engine owns the journal (its parked windows
/// are parked on purpose), or one recovery pass does, never both and never two passes at once.
///
/// - `tryBeginEngine()` gives the engine a lease when the journal is free (no pass, no earlier engine) and `nil`
///   otherwise; `waitUntilIdle()` waits for it to be free (the caller bounds the wait). The engine owns the journal
///   until `endEngine(_:)` with that lease, which the runtime calls only after the engine has really stopped, not
///   when a stop budget ran out. A stale lease changes nothing, so an old engine that stops late cannot free the
///   journal under a new one.
/// - `exclusive(_:)` runs one pass or answers `Pass.engineRunning` / `Pass.engineStopping`; a caller that finds the
///   engine stopping reports `.deferred` so the host tries again. Other passes wait their turn.
///
/// One owner exists per storage folder and app instance: `JournalOwner.owner(for:)` takes it from the context's
/// `PluginServices`, so no process-wide global is involved.
actor JournalOwner {
    enum Phase: Equatable, Sendable {
        case idle
        case recovering
        case engine
        case stopping
    }

    enum Pass<Value: Sendable>: Sendable {
        case ran(Value)
        case engineRunning
        case engineStopping
        /// The waiting caller was cancelled before its turn: nothing ran.
        case cancelled
    }

    nonisolated let store: StateStore
    nonisolated let reports = ReportSink()
    private(set) var phase = Phase.idle
    private var activeLease: UInt64?
    private var nextLease: UInt64 = 0
    private var turns: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextTurn: UInt64 = 0
    private var launchCounted = false

    init(directory: URL, clock: any Clock<Duration> = ContinuousClock(), logger: Logger) {
        store = StateStore(directory: directory, clock: clock, logger: logger)
    }

    // MARK: Engine

    /// Gives the engine ownership when the journal is free. Returns the lease the engine must present, or `nil`
    /// while a recovery pass or an earlier engine (still stopping) holds it.
    func tryBeginEngine() -> UInt64? {
        guard phase == .idle else { return nil }
        nextLease += 1
        activeLease = nextLease
        phase = .engine
        return nextLease
    }

    /// Waits until no pass and no engine holds the journal. Unbounded, but cancellable: a cancelled caller leaves
    /// the queue at once (callers put a deadline around it).
    func waitUntilIdle() async {
        while phase != .idle, !Task.isCancelled { await waitForTurn() }
    }

    /// The engine of `lease` is being stopped: recovery passes answer `.engineStopping` until `endEngine`.
    func engineStopping(_ lease: UInt64) {
        if phase == .engine, activeLease == lease { phase = .stopping }
    }

    /// The engine of `lease` has stopped for good: the journal is free. A lease that is not the current one is
    /// ignored.
    func endEngine(_ lease: UInt64) {
        guard activeLease == lease, phase == .engine || phase == .stopping else { return }
        activeLease = nil
        phase = .idle
        wake()
    }

    // MARK: Passes

    /// Runs `body` as the only user of the journal, or reports who owns it.
    func exclusive<Value: Sendable>(
        _ body: @Sendable (StateStore) async -> Value
    ) async -> Pass<Value> {
        while phase == .recovering {
            if Task.isCancelled { return .cancelled }
            await waitForTurn()
        }
        switch phase {
        case .engine: return .engineRunning
        case .stopping: return .engineStopping
        case .idle, .recovering:
            phase = .recovering
            let value = await body(store)
            phase = .idle
            wake()
            return .ran(value)
        }
    }

    /// True once per launch of the app: a retry of the same launch is not a launch.
    func claimLaunch() -> Bool {
        defer { launchCounted = true }
        return !launchCounted
    }

    /// Parks until the next `wake()` or until the calling task is cancelled; either way the caller's entry is gone
    /// from `turns` when this returns.
    private func waitForTurn() async {
        nextTurn += 1
        let id = nextTurn
        await withTaskCancellationHandler {
            await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { turn.resume() } else { turns[id] = turn }
            }
        } onCancel: {
            Task { await self.leave(id) }
        }
    }

    private func leave(_ id: UInt64) {
        turns.removeValue(forKey: id)?.resume()
    }

    private func wake() {
        let waiting = turns
        turns = [:]
        for turn in waiting.values { turn.resume() }
    }

    #if DEBUG
    /// How many callers are parked (tests only).
    var waiterCount: Int { turns.count }
    #endif
}

/// Where the HUD states of a recovery pass go. A state that comes before a plugin instance has attached its HUD (the
/// launch recovery runs first) is kept and shown, in order, the moment one does. Attaching is a plain call on the
/// main actor, so nothing hops through a task.
final class ReportSink: Sendable {
    private struct State {
        var handler: (@MainActor (WindowsHUDState) -> Void)?
        var undelivered: [WindowsHUDState] = []
    }

    private let state = Mutex(State())

    @MainActor
    func attach(_ handler: @escaping @MainActor (WindowsHUDState) -> Void) {
        let waiting = state.withLock { state -> [WindowsHUDState] in
            state.handler = handler
            defer { state.undelivered = [] }
            return state.undelivered
        }
        for report in waiting { handler(report) }
    }

    /// Forgets the attached HUD (the plugin's services are torn down).
    func detach() {
        state.withLock { $0.handler = nil }
    }

    func present(_ report: WindowsHUDState) async {
        let handler = state.withLock { state -> (@MainActor (WindowsHUDState) -> Void)? in
            if let handler = state.handler { return handler }
            state.undelivered.append(report)
            return nil
        }
        if let handler { await MainActor.run { handler(report) } }
    }
}

/// The journal owner as a plugin service: one per app instance and plugin, torn down when the host quits. The
/// host's services (`AppPluginServices`) key it by plugin id and the plugin's storage folder is derived from that
/// id, so one app instance has one owner, and one `StateStore` writer, per folder. A context built without a host
/// (`UnsharedPluginServices`) shares nothing: tests that need one owner pass one services object to every context.
enum JournalOwnerKey: PluginServiceKey {
    static func make(context: PluginContext) -> JournalOwner {
        JournalOwner(directory: context.storageDirectory, clock: context.clock, logger: context.logger)
    }

    static func teardown(_ owner: JournalOwner) {
        // The HUD handler of the last plugin instance must not outlive the app's plugins.
        owner.reports.detach()
    }
}

extension JournalOwner {
    /// The owner of `context`'s storage folder in this app instance.
    static func owner(for context: PluginContext) -> JournalOwner {
        context.services.value(JournalOwnerKey.self, for: context)
    }
}
