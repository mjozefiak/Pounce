import Synchronization

/// Runs work on serial lanes: in submission order within one lane, in parallel across lanes. One task per piece
/// of work; the task is its lane's tail, so a lane that has gone quiet holds nothing.
final class LaneScheduler<Key: Hashable & Sendable>: Sendable {
    private struct Tail {
        var id: UInt64
        var task: Task<Void, Never>
    }

    private struct State {
        var tails: [Key: Tail] = [:]
        var next: UInt64 = 0
    }

    private let state = Mutex(State())

    /// Queues `work` behind everything already on `key`'s lane; `then` receives its result on the same task.
    func run<Result: Sendable>(
        on key: Key, work: @escaping @Sendable () async -> Result,
        then: @escaping @Sendable (Result) async -> Void
    ) {
        state.withLock { state in
            state.next += 1
            let id = state.next
            let previous = state.tails[key]?.task
            let task = Task { [weak self] in
                await previous?.value
                await then(await work())
                self?.finish(key, id)
            }
            state.tails[key] = Tail(id: id, task: task)
        }
    }

    private func finish(_ key: Key, _ id: UInt64) {
        state.withLock { if $0.tails[key]?.id == id { $0.tails[key] = nil } }
    }
}

/// A value that is set once; readers wait until it is.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    private let state = Mutex(State())

    func set(_ value: Value) {
        let waiters = state.withLock { state -> [CheckedContinuation<Value, Never>] in
            guard state.value == nil else { return [] }
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Value? in
                if let value = state.value { return value }
                state.waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}
