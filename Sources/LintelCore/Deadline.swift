import Synchronization

/// Runs `work` and returns what it answers, or `nil` when `budget` passes first.
///
/// `work` runs as a task of its own and is never cancelled and never waited for once the budget has passed, so a
/// blocking call (an Accessibility request, a Keychain read) cannot hold the caller up longer than the budget.
/// What the caller does about work that is still running is its own decision: it keeps the handle itself when it
/// must not start a second copy. Cancelling the caller returns `nil` at once. Time comes from `clock`, so a test
/// with a virtual clock needs no real wait.
public func withDeadline<Value: Sendable>(
    _ budget: Duration, clock: any Clock<Duration>, _ work: @escaping @Sendable () async -> Value
) async -> Value? {
    let latch = DeadlineLatch<Value>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            latch.install(continuation)
            let job = Task { latch.resolve(await work()) }
            let deadline = Task {
                do {
                    try await clock.sleep(for: budget)
                    latch.resolve(nil)
                } catch {
                    // Cancelled because the work answered first.
                }
            }
            latch.track(deadline)
            _ = job
        }
    } onCancel: {
        latch.resolve(nil)
    }
}

/// Resumes the continuation exactly once with the first answer, then cancels the deadline.
private final class DeadlineLatch<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value?, Never>?
        var resolved = false
        var answer: Value?
        var deadline: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        let early = state.withLock { state -> (Bool, Value?) in
            if state.resolved { return (true, state.answer) }
            state.continuation = continuation
            return (false, nil)
        }
        if early.0 { continuation.resume(returning: early.1) }
    }

    func track(_ deadline: Task<Void, Never>) {
        let cancelNow = state.withLock { state -> Bool in
            if state.resolved { return true }
            state.deadline = deadline
            return false
        }
        if cancelNow { deadline.cancel() }
    }

    func resolve(_ value: Value?) {
        let (continuation, deadline) = state.withLock {
            state -> (CheckedContinuation<Value?, Never>?, Task<Void, Never>?) in
            guard !state.resolved else { return (nil, nil) }
            state.resolved = true
            state.answer = value
            let pair = (state.continuation, state.deadline)
            state.continuation = nil
            state.deadline = nil
            return pair
        }
        continuation?.resume(returning: value)
        deadline?.cancel()
    }
}
