import Observation
import Testing

/// A counter that only goes up, with waiters. For "the fake was called N times" and "N events were published".
public final class CountLatch: Sendable {
    private let state = Waitable(0)

    public init() {}

    public var count: Int { state.read { $0 } }

    /// Diagnostics for the module's own tests: waiters stored and guard timers still running.
    var pendingWaiters: Int { state.pendingWaiters }
    var liveTimers: Int { state.liveTimers }

    @discardableResult
    public func increment() -> Int {
        state.mutate { value -> Int in
            value += 1
            return value
        }
    }

    @discardableResult
    public func wait(
        atLeast target: Int,
        guard limit: Duration = .seconds(60),
        _ what: String = "the count to be reached",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await state.wait("\(what) (\(target))", guard: limit, sourceLocation: sourceLocation) { $0 >= target }
    }
}

/// A one-shot gate: closed until `open()`, then open for good.
public final class Latch: Sendable {
    private let state = Waitable(false)

    public init() {}

    public var isOpen: Bool { state.read { $0 } }

    /// Diagnostics for the module's own tests: waiters stored and guard timers still running.
    var pendingWaiters: Int { state.pendingWaiters }
    var liveTimers: Int { state.liveTimers }

    public func open() { state.mutate { $0 = true } }

    @discardableResult
    public func wait(
        guard limit: Duration = .seconds(60),
        _ what: String = "the latch to open",
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await state.wait(what, guard: limit, sourceLocation: sourceLocation) { $0 }
    }
}

/// "Look again when poked", for state that has no stream of its own. Whoever changes the state calls `ring()`;
/// the waiter re-checks its condition after every ring, so a ring that nobody waits for is not lost: the
/// generation is read BEFORE the condition is evaluated.
public final class ChangeBell: Sendable {
    private let state = Waitable(0)

    public init() {}

    public func ring() { state.mutate { $0 += 1 } }

    var generation: Int { state.read { $0 } }

    func waitForRing(after seen: Int, guard limit: Duration) async -> WaitOutcome {
        await state.waitOutcome(guard: limit, until: { $0 > seen })
    }

    @discardableResult
    public func wait(
        guard limit: Duration = .seconds(60),
        _ what: String = "the condition to hold",
        sourceLocation: SourceLocation = #_sourceLocation,
        until condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while true {
            let seen = state.read { $0 }
            if condition() { return true }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            switch await waitForRing(after: seen, guard: remaining) {
            case .satisfied, .expired: continue
            case .cancelled: return false
            }
        }
        if condition() { return true }
        recordTimeout(what, limit, sourceLocation)
        return false
    }
}

/// Waits for `@Observable` state on the main actor with `withObservationTracking`: no polling, no yield counts.
///
/// The condition is evaluated again after every change notification. `onChange` fires on `willSet`, so the
/// re-evaluation is reliable for state that is changed on the main actor (the case this is for): the main actor
/// is busy with the mutation until it has finished.
@MainActor
@discardableResult
public func waitForObserved(
    _ what: String,
    guard limit: Duration = .seconds(60),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let bell = ChangeBell()
    let deadline = ContinuousClock.now.advanced(by: limit)
    while true {
        let seen = bell.generation
        let satisfied = withObservationTracking({ condition() }, onChange: { bell.ring() })
        if satisfied { return true }
        let remaining = ContinuousClock.now.duration(to: deadline)
        if remaining <= .zero { break }
        switch await bell.waitForRing(after: seen, guard: remaining) {
        case .cancelled: return false
        case .satisfied, .expired: continue
        }
    }
    if condition() { return true }
    recordTimeout(what, limit, sourceLocation)
    return false
}

/// Last resort when no event exists: polls in real time, and says so in its name. Prefer `CountLatch`, `Latch`,
/// `ChangeBell` or `waitForObserved`.
@discardableResult
public func pollUntil(
    _ what: String,
    guard limit: Duration = .seconds(60),
    every interval: Duration = .milliseconds(10),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: limit)
    while true {
        if await condition() { return true }
        if Task.isCancelled { return false }
        guard ContinuousClock.now < deadline else { break }
        do { try await Task.sleep(for: interval) } catch { return false }
    }
    recordTimeout(what, limit, sourceLocation)
    return false
}
