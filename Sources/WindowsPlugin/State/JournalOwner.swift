import Foundation
import LintelKit
import os

/// The one owner of `Plugins/windows/state.json` for a storage folder: it holds the only `StateStore` (the single
/// writer of the file) and decides who may use it. Either the running engine owns the journal (its parked windows
/// are parked on purpose), or one recovery pass does, never both and never two passes at once.
///
/// - `beginEngine()` waits until the journal is free (no pass, no earlier engine), then returns a lease; the engine
///   owns the journal until `endEngine(_:)` with that lease, which the runtime calls only after the engine has
///   really stopped, not when a stop budget ran out. A stale lease changes nothing, so an old engine that stops late
///   cannot free the journal under a new one.
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
    }

    nonisolated let store: StateStore
    private(set) var phase = Phase.idle
    private var activeLease: UInt64?
    private var nextLease: UInt64 = 0
    private var turns: [CheckedContinuation<Void, Never>] = []
    private var launchCounted = false
    private var sink: (@Sendable (WindowsHUDState) async -> Void)?
    private var undelivered: [WindowsHUDState] = []

    init(directory: URL, clock: any Clock<Duration> = ContinuousClock(), logger: Logger) {
        store = StateStore(directory: directory, clock: clock, logger: logger)
    }

    // MARK: Engine

    /// Waits until the journal is free, then gives the engine ownership. Returns the lease the engine must present.
    func beginEngine() async -> UInt64 {
        while phase != .idle { await waitForTurn() }
        nextLease += 1
        activeLease = nextLease
        phase = .engine
        return nextLease
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
        while phase == .recovering { await waitForTurn() }
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

    private func waitForTurn() async {
        await withCheckedContinuation { turns.append($0) }
    }

    private func wake() {
        let waiting = turns
        turns = []
        for turn in waiting { turn.resume() }
    }

    // MARK: Reports

    /// Where the HUD states of a recovery pass go. States that came before a plugin instance set one are
    /// delivered at once, in order.
    func setSink(_ sink: @escaping @Sendable (WindowsHUDState) async -> Void) async {
        self.sink = sink
        let waiting = undelivered
        undelivered = []
        for state in waiting { await sink(state) }
    }

    func present(_ state: WindowsHUDState) async {
        if let sink { await sink(state) } else { undelivered.append(state) }
    }
}

extension JournalOwner {
    /// The owner of `context`'s storage folder in this app instance.
    static func owner(for context: PluginContext) -> JournalOwner {
        context.services.shared("windows.journal:\(context.storageDirectory.standardizedFileURL.path)") {
            JournalOwner(directory: context.storageDirectory, clock: context.clock, logger: context.logger)
        }
    }
}
