import LintelKit
import Synchronization

/// Runs one `recoverAtLaunch` with a time bound. When the bound passes first the answer is `.deferred` (the
/// plugin keeps what is left to do) and the work is cancelled; the caller does not wait for work that ignores
/// cancellation.
nonisolated enum RecoveryRunner {
    static func run(
        budget: Duration,
        clock: any Clock<Duration>,
        _ work: @escaping @Sendable () async -> RecoveryOutcome
    ) async -> RecoveryOutcome {
        let latch = Latch()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                latch.install(continuation)
                let job = Task {
                    latch.resolve(await work())
                }
                let deadline = Task {
                    do {
                        try await clock.sleep(for: budget)
                        latch.resolve(.deferred)
                    } catch {
                        // Cancelled because the work answered first.
                    }
                }
                latch.track(job)
                latch.track(deadline)
            }
        } onCancel: {
            latch.resolve(.deferred)
        }
    }

    /// Resumes the continuation exactly once with the first answer, then cancels the other task.
    private final class Latch: Sendable {
        private struct State {
            var continuation: CheckedContinuation<RecoveryOutcome, Never>?
            var outcome: RecoveryOutcome?
            var tasks: [Task<Void, Never>] = []
        }

        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<RecoveryOutcome, Never>) {
            let early = state.withLock { state -> RecoveryOutcome? in
                if let outcome = state.outcome { return outcome }
                state.continuation = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }

        func track(_ task: Task<Void, Never>) {
            let cancelNow = state.withLock { state -> Bool in
                if state.outcome != nil { return true }
                state.tasks.append(task)
                return false
            }
            if cancelNow { task.cancel() }
        }

        func resolve(_ outcome: RecoveryOutcome) {
            let (continuation, tasks) = state.withLock {
                state -> (CheckedContinuation<RecoveryOutcome, Never>?, [Task<Void, Never>]) in
                guard state.outcome == nil else { return (nil, []) }
                state.outcome = outcome
                let pair = (state.continuation, state.tasks)
                state.continuation = nil
                state.tasks = []
                return pair
            }
            continuation?.resume(returning: outcome)
            for task in tasks { task.cancel() }
        }
    }
}
