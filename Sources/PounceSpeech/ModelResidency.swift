import Foundation
import Synchronization

/// Who is asking for a model. The dictation shortcut is `interactive`; meeting segments and notes are
/// `background` and give way (spec: Dzierżawy modeli).
public enum LeasePriority: Int, Comparable, Sendable {
    case background = 0
    case interactive = 1

    public static func < (lhs: LeasePriority, rhs: LeasePriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ModelLeaseError: Error, Equatable, Sendable {
    /// Another model (a different key) is in use right now; try again after its users are done.
    case busy
    /// The handle was released already.
    case released
}

/// Keeps at most one model resident and hands it out under a key. The same key is shared (a counter); a
/// different key while any lease is active is refused with `busy`; a different key while the resident model is
/// idle replaces it at once. The keep-warm time runs from the release of the last lease.
///
/// Every load and unload goes through one chain (`tail`), so an unload that is still running finishes before the
/// next load starts, even though the actor is re-entered while it awaits.
actor Residency<Key: Hashable & Sendable, Model: Sendable> {
    struct Ops: Sendable {
        let isLoaded: @Sendable (Model) async -> Bool
        let unload: @Sendable (Model) async -> Void
    }

    private struct Resident {
        let key: Key
        let model: Model
        var leases: Int
        var timer: Task<Void, Never>?
        var generation: Int
    }

    private let ops: Ops
    private let sleep: @Sendable (Duration) async throws -> Void
    private var resident: Resident?
    private var tail: Task<Void, Never>?
    private var generations = 0

    init(ops: Ops, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.ops = ops
        self.sleep = sleep
    }

    var residentKey: Key? { resident?.key }
    var activeLeases: Int { resident?.leases ?? 0 }

    /// Takes a lease on `key`. Returns the model to use: the resident one when the key is already held,
    /// otherwise `model` after `load` ran (skipped when it reports loaded).
    func acquire(key: Key, model: Model, load: @escaping @Sendable (Model) async throws -> Void) async throws -> Model {
        var evicted: Model?
        let active: Model
        if var current = resident {
            if current.key == key {
                current.timer?.cancel()
                current.timer = nil
                current.leases += 1
                resident = current
                active = current.model
            } else if current.leases > 0 {
                throw ModelLeaseError.busy
            } else {
                current.timer?.cancel()
                evicted = current.model
                resident = Resident(key: key, model: model, leases: 1, timer: nil, generation: 0)
                active = model
            }
        } else {
            resident = Resident(key: key, model: model, leases: 1, timer: nil, generation: 0)
            active = model
        }
        let previous = tail
        let ops = ops
        let work = Task<Void, any Error> { [evicted] in
            await previous?.value
            if let evicted { await ops.unload(evicted) }
            if await !ops.isLoaded(active) { try await load(active) }
        }
        tail = Task { _ = await work.result }
        do {
            try await work.value
        } catch {
            giveBack(key)
            throw error
        }
        return active
    }

    /// Gives one lease back; the last one starts the keep-warm timer.
    func release(key: Key, keepWarm: Duration) {
        guard var current = resident, current.key == key, current.leases > 0 else { return }
        current.leases -= 1
        if current.leases == 0 {
            generations += 1
            let generation = generations
            current.generation = generation
            let sleep = sleep
            current.timer = Task {
                do { try await sleep(keepWarm) } catch { return }
                await self.expire(generation)
            }
        }
        resident = current
    }

    /// Unloads the resident model now when nobody holds a lease; returns when the unload is done.
    func evictIdle() async {
        if let current = resident, current.leases == 0 { evict(current) }
        await tail?.value
    }

    private func expire(_ generation: Int) {
        guard let current = resident, current.leases == 0, current.generation == generation else { return }
        evict(current)
    }

    private func evict(_ current: Resident) {
        current.timer?.cancel()
        resident = nil
        let previous = tail
        let ops = ops
        let model = current.model
        tail = Task {
            await previous?.value
            await ops.unload(model)
        }
    }

    private func giveBack(_ key: Key) {
        guard var current = resident, current.key == key else { return }
        current.leases = max(0, current.leases - 1)
        resident = current.leases == 0 ? nil : current
    }
}

/// One user of the model at a time, `interactive` before `background`, first come first served within a
/// priority. A `background` holder is told to give up (`preempt`) when an `interactive` request arrives.
final class Turnstile: Sendable {
    typealias Preempt = @Sendable () -> Void

    private struct Waiter {
        let id: UInt64
        let priority: LeasePriority
        let preempt: Preempt
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var holder: (priority: LeasePriority, preempt: Preempt)?
        var waiters: [Waiter] = []
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Requests waiting for their turn (not the one running).
    var waiting: Int { state.withLock { $0.waiters.count } }

    private enum Entry {
        case run
        case wait(victim: Preempt?)
        case cancelled
    }

    func enter(_ priority: LeasePriority, preempt: @escaping Preempt = {}) async throws {
        let id = state.withLock { state -> UInt64 in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let entry = state.withLock { state -> Entry in
                    if Task.isCancelled { return .cancelled }
                    guard let holder = state.holder else {
                        state.holder = (priority, preempt)
                        return .run
                    }
                    state.waiters.append(
                        Waiter(id: id, priority: priority, preempt: preempt, continuation: continuation))
                    let victim = priority == .interactive && holder.priority == .background ? holder.preempt : nil
                    return .wait(victim: victim)
                }
                switch entry {
                case .run: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .wait(let victim): victim?()
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func leave() {
        let next = state.withLock { state -> Waiter? in
            let index =
                state.waiters.firstIndex(where: { $0.priority == .interactive }) ?? state.waiters.indices.first
            guard let index else {
                state.holder = nil
                return nil
            }
            let waiter = state.waiters.remove(at: index)
            state.holder = (waiter.priority, waiter.preempt)
            return waiter
        }
        next?.continuation.resume()
    }
}
