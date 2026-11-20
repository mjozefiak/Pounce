import Synchronization
import Testing

/// How a bounded wait ended.
enum WaitOutcome: Sendable {
    case satisfied
    /// The guard expired. The only outcome that records an `Issue`.
    case expired
    /// The waiting task was cancelled.
    case cancelled
}

/// A value under one lock, plus waiters on a predicate over that value.
///
/// Every primitive in this module is built on it, so they share three guarantees:
/// - A waiter is resumed exactly once. Whoever removes it from the table under the lock is the only one who resumes
///   it: a mutation that satisfies it, the guard timer, or cancellation.
/// - Cancellation is read under the same lock that stores the continuation (`Task.isCancelled` inside `register`),
///   so a cancel that lands before the waiter is stored is seen by the registration, and a cancel that lands after
///   finds the stored waiter. There is no window in which neither happens.
/// - The guard timer is a task that is cancelled and awaited before `wait` returns, so no task outlives a wait.
final class Waitable<Value: Sendable>: Sendable {
    private struct Waiter: Sendable {
        let predicate: @Sendable (Value) -> Bool
        let continuation: CheckedContinuation<WaitOutcome, Never>
    }

    private struct Inner: Sendable {
        var value: Value
        var nextID = 0
        var waiters: [Int: Waiter] = [:]
        /// An outcome decided before the waiter was stored (a guard that fired first).
        var early: [Int: WaitOutcome] = [:]
        var liveTimers = 0
    }

    private let inner: Mutex<Inner>

    init(_ value: Value) {
        inner = Mutex(Inner(value: value))
    }

    /// Reads the value.
    func read<R: Sendable>(_ body: (Value) -> R) -> R {
        inner.withLock { body($0.value) }
    }

    /// Mutates the value and resumes every waiter whose predicate now holds, outside the lock.
    @discardableResult
    func mutate<R: Sendable>(_ body: (inout Value) -> R) -> R {
        let (result, ready) = inner.withLock { state -> (R, [CheckedContinuation<WaitOutcome, Never>]) in
            let result = body(&state.value)
            var ready: [CheckedContinuation<WaitOutcome, Never>] = []
            for (id, waiter) in state.waiters where waiter.predicate(state.value) {
                ready.append(waiter.continuation)
                state.waiters[id] = nil
            }
            return (result, ready)
        }
        for continuation in ready { continuation.resume(returning: .satisfied) }
        return result
    }

    /// Waiters currently stored (diagnostics for the module's own tests).
    var pendingWaiters: Int { inner.withLock { $0.waiters.count + $0.early.count } }
    /// Guard timers that have not finished yet (diagnostics for the module's own tests).
    var liveTimers: Int { inner.withLock { $0.liveTimers } }

    private func finish(_ id: Int, _ outcome: WaitOutcome) {
        let continuation = inner.withLock { state -> CheckedContinuation<WaitOutcome, Never>? in
            if let waiter = state.waiters.removeValue(forKey: id) { return waiter.continuation }
            state.early[id] = outcome
            return nil
        }
        continuation?.resume(returning: outcome)
    }

    /// Waits until `predicate` holds for the value. Never throws, never records: the caller decides what an
    /// `expired` outcome means.
    func waitOutcome(
        guard limit: Duration,
        until predicate: @escaping @Sendable (Value) -> Bool
    ) async -> WaitOutcome {
        let id = inner.withLock { state -> Int in
            state.nextID += 1
            state.liveTimers += 1
            return state.nextID
        }
        let timer = Task { [self] in
            defer { inner.withLock { $0.liveTimers -= 1 } }
            do { try await Task.sleep(for: limit) } catch { return }
            finish(id, .expired)
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitOutcome, Never>) in
                let immediate = inner.withLock { state -> WaitOutcome? in
                    if let early = state.early.removeValue(forKey: id) { return early }
                    if Task.isCancelled { return .cancelled }
                    if predicate(state.value) { return .satisfied }
                    state.waiters[id] = Waiter(predicate: predicate, continuation: continuation)
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            finish(id, .cancelled)
        }
        timer.cancel()
        await timer.value
        // The timer and the cancellation handler are finished: nothing can write `early[id]` any more.
        inner.withLock { _ = $0.early.removeValue(forKey: id) }
        return outcome
    }

    /// `waitOutcome` plus the module's rule: an expired guard records ONE issue naming what was awaited, at the
    /// caller's line, and the answer is `false`. A cancelled wait answers `false` without an issue.
    func wait(
        _ what: String,
        guard limit: Duration,
        sourceLocation: SourceLocation,
        until predicate: @escaping @Sendable (Value) -> Bool
    ) async -> Bool {
        switch await waitOutcome(guard: limit, until: predicate) {
        case .satisfied: return true
        case .cancelled: return false
        case .expired:
            recordTimeout(what, limit, sourceLocation)
            return false
        }
    }
}

func recordTimeout(_ what: String, _ limit: Duration, _ sourceLocation: SourceLocation) {
    Issue.record("Timed out after \(limit) waiting for \(what)", sourceLocation: sourceLocation)
}
