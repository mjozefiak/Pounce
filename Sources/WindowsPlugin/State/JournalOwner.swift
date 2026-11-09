import Foundation
import LintelKit
import Synchronization
import os

/// The one owner of `Plugins/windows/state.json` for a storage folder: it holds the only `StateStore` (the single
/// writer of the file) and decides who may use it. Either the running engine owns the journal (its parked windows
/// are parked on purpose), or one recovery pass does, never both and never two passes at once.
///
/// - `beginEngine()` waits for a pass in progress, then the engine owns the journal until `endEngine()`, which
///   the runtime calls only after the engine has really stopped, not when a stop budget ran out.
/// - `recover` and `restore` run one pass exclusively: `.engineRunning` / `.engineStopping` when the engine owns
///   the journal, otherwise the pass runs and any other caller waits its turn.
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
    private var turns: [CheckedContinuation<Void, Never>] = []
    private var launchCounted = false
    private var sink: (@Sendable (WindowsHUDState) async -> Void)?
    private var undelivered: [WindowsHUDState] = []

    init(directory: URL, clock: any Clock<Duration> = ContinuousClock(), logger: Logger) {
        store = StateStore(directory: directory, clock: clock, logger: logger)
    }

    // MARK: Engine

    func beginEngine() async {
        while phase == .recovering || phase == .stopping { await waitForTurn() }
        phase = .engine
    }

    /// The engine is being stopped: recovery passes wait (answering `.deferred`) until `endEngine()`.
    func engineStopping() {
        if phase == .engine { phase = .stopping }
    }

    func endEngine() {
        guard phase == .engine || phase == .stopping else { return }
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

/// Hands out one `JournalOwner` per storage folder, so the launch recovery (which runs before any plugin
/// instance exists and again on activation) and the running engine share one writer. The app uses `shared`;
/// tests pass their own.
final class JournalRegistry: Sendable {
    static let shared = JournalRegistry()

    private let owners = Mutex<[String: JournalOwner]>([:])

    func owner(for directory: URL, clock: any Clock<Duration>, logger: Logger) -> JournalOwner {
        let key = directory.standardizedFileURL.path
        return owners.withLock { owners in
            if let existing = owners[key] { return existing }
            let created = JournalOwner(directory: directory, clock: clock, logger: logger)
            owners[key] = created
            return created
        }
    }
}
