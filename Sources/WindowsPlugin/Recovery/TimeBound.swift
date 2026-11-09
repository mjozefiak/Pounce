import Foundation
import Synchronization

/// Runs `work` for at most `budget`: `true` when it finished first. Work that ignores cancellation (a blocking
/// Accessibility call) is not waited for once the bound passes, so a quit or a disable is never held up longer
/// than the bound; what it did not finish stays in the journal for the next launch.
enum TimeBound {
    static func run(
        budget: Duration, clock: any Clock<Duration>, _ work: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let latch = Latch()
        return await withCheckedContinuation { continuation in
            latch.install(continuation)
            let job = Task {
                await work()
                latch.resolve(true)
            }
            let deadline = Task {
                do {
                    try await clock.sleep(for: budget)
                    latch.resolve(false)
                } catch {}
            }
            latch.track(job, deadline)
        }
    }

    private final class Latch: Sendable {
        private struct State {
            var continuation: CheckedContinuation<Bool, Never>?
            var outcome: Bool?
            var deadline: Task<Void, Never>?
        }

        private let state = Mutex(State())

        func install(_ continuation: CheckedContinuation<Bool, Never>) {
            state.withLock { $0.continuation = continuation }
        }

        /// Only the deadline is cancelled when the work wins; the work is never cancelled (it must finish what it
        /// started, or leave it in the journal).
        func track(_ job: Task<Void, Never>, _ deadline: Task<Void, Never>) {
            let cancelNow = state.withLock { state -> Bool in
                if state.outcome != nil { return true }
                state.deadline = deadline
                return false
            }
            if cancelNow { deadline.cancel() }
        }

        func resolve(_ finished: Bool) {
            let (continuation, deadline) = state.withLock {
                state -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
                guard state.outcome == nil else { return (nil, nil) }
                state.outcome = finished
                let pair = (state.continuation, state.deadline)
                state.continuation = nil
                state.deadline = nil
                return pair
            }
            continuation?.resume(returning: finished)
            deadline?.cancel()
        }
    }
}
