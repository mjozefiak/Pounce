import Foundation
import PounceSpeech
import Synchronization

/// Runs one model request and gives up on it after a time limit **of generation**, without waiting for the
/// request to finish: a model load or a decode that ignores cancellation cannot delay the timeout.
///
/// The limit counts only the time the request is `running` on the model. While it waits for its turn behind a
/// dictation request, or after a preemption until it is generated again, the clock is stopped, so the time
/// another feature holds the model is never counted against the notes.
enum NotesDeadline {
    /// The operation's value, or `nil` when the generation time ran out first. Cancelling the caller cancels
    /// the operation and throws `CancellationError`. The operation reports its phase through the closure.
    static func run<T: Sendable>(
        limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ operation: @escaping @Sendable (@escaping @Sendable (GenerationPhase) -> Void) async throws -> T
    ) async throws -> T? {
        let gate = Gate<T?>()
        let clock = ActiveClock(limit: limit, sleep: sleep) { gate.finish(.success(nil)) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, any Error>) in
                gate.install(continuation)
                let work = Task {
                    do {
                        gate.finish(.success(try await operation { clock.phase($0) }))
                    } catch {
                        gate.finish(.failure(error))
                    }
                }
                gate.onFinish {
                    work.cancel()
                    clock.stop()
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Time spent running; a timer is armed for what is left each time the request starts running.
    final class ActiveClock: Sendable {
        private struct State {
            var remaining: Duration
            var runningSince: ContinuousClock.Instant?
            var timer: Task<Void, Never>?
            var stopped = false
        }

        private let state: Mutex<State>
        private let sleep: @Sendable (Duration) async throws -> Void
        private let expired: @Sendable () -> Void

        init(
            limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
            expired: @escaping @Sendable () -> Void
        ) {
            state = Mutex(State(remaining: limit))
            self.sleep = sleep
            self.expired = expired
        }

        func phase(_ phase: GenerationPhase) {
            switch phase {
            case .running:
                let delay: Duration? = state.withLock { state in
                    guard !state.stopped, state.runningSince == nil else { return nil }
                    state.runningSince = .now
                    return state.remaining
                }
                guard let delay else { return }
                let sleep = sleep
                let expired = expired
                let timer = Task {
                    do {
                        if delay > .zero { try await sleep(delay) }
                    } catch { return }
                    if !Task.isCancelled { expired() }
                }
                state.withLock { state in
                    if state.stopped || state.runningSince == nil {
                        timer.cancel()
                    } else {
                        state.timer = timer
                    }
                }
            case .queued:
                let timer: Task<Void, Never>? = state.withLock { state in
                    guard let since = state.runningSince else { return nil }
                    state.remaining -= ContinuousClock.now - since
                    state.runningSince = nil
                    defer { state.timer = nil }
                    return state.timer
                }
                timer?.cancel()
            }
        }

        func stop() {
            let timer: Task<Void, Never>? = state.withLock { state in
                state.stopped = true
                defer { state.timer = nil }
                return state.timer
            }
            timer?.cancel()
        }
    }

    /// Resumes the continuation exactly once, with whichever result arrives first.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var cleanup: (@Sendable () -> Void)?
        private var early: Result<T, any Error>?
        private var done = false

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            defer { lock.unlock() }
            if let early {
                done = true
                continuation.resume(with: early)
            } else {
                self.continuation = continuation
            }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            lock.lock()
            let run = done
            if !run { self.cleanup = cleanup }
            lock.unlock()
            if run { cleanup() }
        }

        func finish(_ result: Result<T, any Error>) {
            lock.lock()
            if done {
                lock.unlock()
                return
            }
            guard let continuation else {
                if early == nil { early = result }
                lock.unlock()
                return
            }
            done = true
            self.continuation = nil
            let cleanup = self.cleanup
            lock.unlock()
            continuation.resume(with: result)
            cleanup?()
        }
    }
}
