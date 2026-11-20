import Foundation
import Testing

/// A point on a test clock: an offset from the clock's start.
public struct TestInstant: InstantProtocol, Hashable, Sendable {
    public var offset: Duration

    public init(offset: Duration = .zero) { self.offset = offset }

    public func advanced(by duration: Duration) -> TestInstant { TestInstant(offset: offset + duration) }
    public func duration(to other: TestInstant) -> Duration { other.offset - offset }
    public static func < (lhs: TestInstant, rhs: TestInstant) -> Bool { lhs.offset < rhs.offset }
}

/// Manual time. `advance(by:)` moves it; nothing else does.
///
/// Registration is atomic: cancellation is read under the lock that stores the continuation, so a sleeper that was
/// cancelled is never left in the table (`sleeperCount` never counts one) and every sleep ends exactly once, by an
/// advance or by cancellation.
public final class TestClock: Clock, Sendable {
    public typealias Instant = TestInstant

    private struct Sleeper {
        let id: Int
        let deadline: TestInstant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: TestInstant
        var nextID = 0
        var sleepers: [Int: Sleeper] = [:]
        var sleepCalls = 0
        var cancelledSleeps = 0
        var wokenDeadlines: [TestInstant] = []
    }

    private let state: Waitable<State>

    public init(start: Duration = .zero) {
        state = Waitable(State(now: TestInstant(offset: start)))
    }

    public var now: TestInstant { state.read { $0.now } }
    public var minimumResolution: Duration { .nanoseconds(1) }
    /// Sleeps that are asleep right now. A cancelled sleeper is never counted.
    public var sleeperCount: Int { state.read { $0.sleepers.count } }
    /// Every call to `sleep`, including those that returned or threw at once.
    public var sleepCalls: Int { state.read { $0.sleepCalls } }

    /// Diagnostics for the module's own tests: waiters stored and guard timers still running.
    var pendingWaiters: Int { state.pendingWaiters }
    var liveTimers: Int { state.liveTimers }
    /// Sleeps that ended by cancellation.
    public var cancelledSleeps: Int { state.read { $0.cancelledSleeps } }
    /// The deadlines of the sleepers `advance` resumed, in the order it resumed them.
    public var wokenDeadlines: [TestInstant] { state.read { $0.wokenDeadlines } }

    public func sleep(until deadline: TestInstant, tolerance: Duration? = nil) async throws {
        let id = state.mutate { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Decision { case suspend, due, cancelled }
                let decision = state.mutate { state -> Decision in
                    state.sleepCalls += 1
                    if Task.isCancelled {
                        state.cancelledSleeps += 1
                        return .cancelled
                    }
                    if deadline <= state.now { return .due }
                    state.sleepers[id] = Sleeper(id: id, deadline: deadline, continuation: continuation)
                    return .suspend
                }
                switch decision {
                case .suspend: break
                case .due: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = state.mutate { state -> CheckedContinuation<Void, any Error>? in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else { return nil }
                state.cancelledSleeps += 1
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper that is now due, earliest deadline first (ties in the order they
    /// went to sleep).
    public func advance(by duration: Duration) {
        let due = state.mutate { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.values
                .filter { $0.deadline <= state.now }
                .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
            for sleeper in due {
                state.sleepers[sleeper.id] = nil
                state.wokenDeadlines.append(sleeper.deadline)
            }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    // MARK: Bounded waits

    /// Waits until at least `count` sleepers are asleep. A sleeper that was cancelled does not count.
    @discardableResult
    public func waitForSleepers(
        _ count: Int,
        guard limit: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await state.wait("\(count) sleeper(s) to be asleep", guard: limit, sourceLocation: sourceLocation) {
            $0.sleepers.count >= count
        }
    }

    /// Waits until `sleep` has been called at least `count` times in total.
    @discardableResult
    public func waitForSleepCalls(
        _ count: Int,
        guard limit: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await state.wait("\(count) call(s) to sleep", guard: limit, sourceLocation: sourceLocation) {
            $0.sleepCalls >= count
        }
    }

    /// Waits until at least `count` sleeps have ended by cancellation.
    @discardableResult
    public func waitForCancelledSleeps(
        _ count: Int,
        guard limit: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await state.wait("\(count) sleep(s) to be cancelled", guard: limit, sourceLocation: sourceLocation) {
            $0.cancelledSleeps >= count
        }
    }

    // MARK: Adapters for ports that are not a `Clock`

    /// For `sleep: (Duration) async throws -> Void` ports.
    public var sleeper: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await sleep(for: duration) }
    }

    /// For `now: () -> Date` ports: `origin` plus the time this clock has advanced.
    public func date(origin: Date = Date(timeIntervalSinceReferenceDate: 0)) -> @Sendable () -> Date {
        { [self] in origin.addingTimeInterval(now.offset.timeInterval) }
    }

    /// For `now: () -> ContinuousClock.Instant` ports.
    public func continuousNow(base: ContinuousClock.Instant) -> @Sendable () -> ContinuousClock.Instant {
        { [self] in base.advanced(by: now.offset) }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval` (nanosecond precision is enough for tests).
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// Sleeps end at once. Time moves forward by the slept duration, every duration is recorded, and a cancelled task
/// still gets `CancellationError`. A loop that sleeps without end is stopped by the spin guard: after
/// `maxSleeps` calls it records one issue and throws `CancellationError`.
public struct ImmediateClock: Clock, Sendable {
    public typealias Instant = TestInstant

    private struct State {
        var now = TestInstant()
        var durations: [Duration] = []
        var spinReported = false
    }

    private let state = Waitable(State())
    public let maxSleeps: Int

    public init(maxSleeps: Int = 20_000) { self.maxSleeps = maxSleeps }

    public var now: TestInstant { state.read { $0.now } }
    public var minimumResolution: Duration { .nanoseconds(1) }
    /// The durations passed to `sleep(for:)`, in order (for `sleep(until:)` the distance to the deadline).
    public var sleptDurations: [Duration] { state.read { $0.durations } }

    public func sleep(until deadline: TestInstant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let verdict = state.mutate { state -> (spin: Bool, first: Bool) in
            let distance = max(state.now.duration(to: deadline), .zero)
            state.durations.append(distance)
            if state.durations.count > maxSleeps {
                defer { state.spinReported = true }
                return (true, !state.spinReported)
            }
            state.now = state.now.advanced(by: distance)
            return (false, false)
        }
        if verdict.spin {
            if verdict.first {
                Issue.record("ImmediateClock: more than \(maxSleeps) sleeps; stopping the loop that spins on it")
            }
            throw CancellationError()
        }
        // Let other work run: an immediate sleep in a loop must not starve the pool.
        await Task.yield()
        try Task.checkCancellation()
    }
}

/// Sleeps that end only by cancellation. Nothing real is waited on: a sleeper is a stored continuation, so a
/// forgotten one is cleaned up when its task is cancelled and costs no timer.
public struct NeverClock: Clock, Sendable {
    public typealias Instant = TestInstant

    private let inner = TestClock()

    public init() {}

    public var now: TestInstant { inner.now }
    public var minimumResolution: Duration { .nanoseconds(1) }
    public var sleeperCount: Int { inner.sleeperCount }

    public func sleep(until deadline: TestInstant, tolerance: Duration? = nil) async throws {
        try await inner.sleep(until: deadline, tolerance: tolerance)
    }

    @discardableResult
    public func waitForSleepers(
        _ count: Int,
        guard limit: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await inner.waitForSleepers(count, guard: limit, sourceLocation: sourceLocation)
    }
}
