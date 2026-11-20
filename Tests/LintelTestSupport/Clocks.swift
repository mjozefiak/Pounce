import Foundation
import Synchronization
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
        var finished = false
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
        enum Decision { case suspend, due, cancelled }
        // Set under the state lock when the sleeper is stored; the cancel handler reads it under the same lock.
        let registered = Mutex<Int?>(nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let decision = state.mutate { state -> Decision in
                    state.sleepCalls += 1
                    if state.finished || Task.isCancelled {
                        state.cancelledSleeps += 1
                        return .cancelled
                    }
                    if deadline <= state.now { return .due }
                    state.nextID += 1
                    let id = state.nextID
                    registered.withLock { $0 = id }
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
            // Read under the state lock, which also serialises the registration: either the sleeper is stored, or
            // the registration has not run yet and will see `Task.isCancelled`.
            let continuation = state.mutate { state -> CheckedContinuation<Void, any Error>? in
                guard let id = registered.withLock({ $0 }), let sleeper = state.sleepers.removeValue(forKey: id) else {
                    return nil
                }
                state.cancelledSleeps += 1
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward by `duration` in ONE step and wakes every sleeper that is now due.
    ///
    /// - Time jumps straight to the end: `advance(by: .seconds(5))` is not five advances of one second. A loop
    ///   that sleeps 1 s and is woken sleeps again until `now + 1 s`, so it ticks once, not five times; call
    ///   `advance` once per tick to drive such a loop.
    /// - The sleepers are RESUMED in deadline order (ties in the order they went to sleep; see `wokenDeadlines`),
    ///   but the woken tasks then run concurrently, in no guaranteed order.
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

    /// Ends the clock: every sleeper wakes with `CancellationError`, every later `sleep` throws it at once, and
    /// the number of sleepers that were still asleep is returned (a leak check for the end of a test).
    @discardableResult
    public func finish() -> Int {
        let left = state.mutate { state -> [Sleeper] in
            state.finished = true
            let left = state.sleepers.values.sorted { $0.id < $1.id }
            state.sleepers.removeAll()
            state.cancelledSleeps += left.count
            return left
        }
        for sleeper in left { sleeper.continuation.resume(throwing: CancellationError()) }
        return left.count
    }

    // MARK: Bounded waits

    /// Waits until at least `count` sleepers are asleep. A sleeper that was cancelled does not count.
    ///
    /// With `dueWithin`, only sleepers whose deadline is at most `dueWithin` after the clock's current time are
    /// counted, so a short timer is not mistaken for a long idle one.
    @discardableResult
    public func waitForSleepers(
        _ count: Int,
        dueWithin horizon: Duration? = nil,
        guard limit: Duration = .seconds(60),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await state.wait("\(count) sleeper(s) to be asleep", guard: limit, sourceLocation: sourceLocation) { state in
            guard let horizon else { return state.sleepers.count >= count }
            let edge = state.now.advanced(by: horizon)
            return state.sleepers.values.filter { $0.deadline <= edge }.count >= count
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
    private let sourceLocation: SourceLocation

    /// `sourceLocation` is where the spin guard's issue points: the test that built the clock.
    public init(maxSleeps: Int = 20_000, sourceLocation: SourceLocation = #_sourceLocation) {
        self.maxSleeps = maxSleeps
        self.sourceLocation = sourceLocation
    }

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
                Issue.record(
                    "ImmediateClock: more than \(maxSleeps) sleeps; stopping the loop that spins on it",
                    sourceLocation: sourceLocation)
            }
            throw CancellationError()
        }
        // Let other work run: an immediate sleep in a loop must not starve the pool.
        await Task.yield()
        try Task.checkCancellation()
    }
}

/// Sleeps that end only by cancellation (a zero or past deadline still returns at once, as on `TestClock`). Nothing real is waited on: a sleeper is a stored continuation, so a
/// forgotten one is cleaned up when its task is cancelled and costs no timer.
public struct NeverClock: Clock, Sendable {
    public typealias Instant = TestInstant

    private let inner = TestClock()

    public init() {}

    public var now: TestInstant { inner.now }
    public var minimumResolution: Duration { .nanoseconds(1) }
    public var sleeperCount: Int { inner.sleeperCount }

    /// Cancels every sleeper and makes later sleeps throw; returns how many were asleep.
    @discardableResult
    public func finish() -> Int { inner.finish() }

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
