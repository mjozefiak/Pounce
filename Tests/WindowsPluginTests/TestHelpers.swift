import Foundation
import Synchronization
import Testing

@testable import WindowsPlugin

/// Lets a test hold something (a recovery pass, a queue's work) until it opens the latch.
actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    var isOpen: Bool { open }

    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

/// Lets other tasks run until `condition` holds (at most `limit` turns); a condition that never holds fails the test
/// instead of hanging it. It is yield counting, so it is used only where the awaited work hops between threads and
/// nothing event-driven exists to wait on; the default bound is tight and a test that needs more says so.
/// (Every suite that waits also has a time limit, so a wait that cannot end fails there too.)
func eventually(_ message: String, limit: Int = 200_000, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<limit {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("never reached: \(message)")
}

/// A value that a task delivers later; the test polls it with a cap instead of awaiting the task.
actor Box<Value: Sendable> {
    private(set) var value: Value?
    func set(_ value: Value) { self.value = value }
    func clear() { value = nil }
}

/// Runs `work` in a task and waits for its answer with the capped `eventually`: an answer that never comes fails the
/// test (`.timeLimit` cannot: it does not interrupt an await that ignores cancellation, measured with a mutant that
/// removed a `cancel()`), and the stuck task is left behind.
func bounded<Value: Sendable>(
    _ message: String, limit: Int = 200_000, _ work: @escaping @Sendable () async -> Value
) async -> Value? {
    let box = Box<Value>()
    Task { await box.set(await work()) }
    await eventually(message, limit: limit) { await box.value != nil }
    return await box.value
}

/// `bounded` for work that must run on the main actor.
@MainActor
func boundedMain<Value: Sendable>(
    _ message: String, limit: Int = 200_000, _ work: @escaping @MainActor @Sendable () async -> Value
) async -> Value? {
    let box = Box<Value>()
    Task { @MainActor in await box.set(await work()) }
    await eventually(message, limit: limit) { await box.value != nil }
    return await box.value
}

/// A count a test waits on without polling: `wait(atLeast:)` returns when the count got there, or, after `limit` of
/// real time, records an Issue instead of hanging (a busy main actor on a loaded runner may be slow, not stuck).
final class CountGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var waiters: [(id: UUID, atLeast: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    var count: Int { lock.withLock { value } }
    func increment() {
        let ready = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            value += 1
            let due = waiters.filter { $0.atLeast <= value }
            waiters.removeAll { $0.atLeast <= value }
            return due.map(\.continuation)
        }
        for continuation in ready { continuation.resume(returning: true) }
    }
    @discardableResult
    func wait(
        atLeast target: Int, limit: Duration = .seconds(60), _ what: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let id = UUID()
        let watchdog = Task { [weak self] in
            try? await ContinuousClock().sleep(for: limit)
            guard !Task.isCancelled, let self else { return }
            let waiter = self.lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return self.waiters.remove(at: index).continuation
            }
            waiter?.resume(returning: false)
        }
        let reached = await withCheckedContinuation { continuation in
            let done = lock.withLock { () -> Bool in
                if value >= target { return true }
                waiters.append((id, target, continuation))
                return false
            }
            if done { continuation.resume(returning: true) }
        }
        watchdog.cancel()
        if !reached { Issue.record("never reached: \(what)", sourceLocation: sourceLocation) }
        return reached
    }
}

/// Waits for `condition` on state that has no event to wait on, by looking every few milliseconds of real time. It
/// ends with an `Issue` at the caller's line after `limit`, and at once when the waiting task is cancelled, so a state
/// that never comes fails the test instead of hanging it. Returns whether the condition held.
@discardableResult
func waitForState(
    _ what: String, limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: limit)
    while !Task.isCancelled {
        if await condition() { return true }
        if clock.now >= deadline { break }
        try? await clock.sleep(for: .milliseconds(5))
    }
    if !Task.isCancelled { Issue.record("never reached within \(limit): \(what)", sourceLocation: sourceLocation) }
    return false
}

/// The first of two outcomes (work finished, or gave up) decides; the waiter gets it once.
private final class Rendezvous: Sendable {
    private struct State {
        var result: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }
    private let state = Mutex(State())

    func finish(_ value: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.result == nil else { return nil }
            state.result = value
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: value)
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            let result = state.withLock { state -> Bool? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let result { continuation.resume(returning: result) }
        }
    }
}

/// Runs `work` and waits for it at most `limit` of real time. A `work` that never finishes (an await that ignores
/// cancellation, a wake-up that never comes) records an `Issue` at the caller's line and returns `false`; the stuck
/// task is left behind. The waiting task being cancelled (`.timeLimit`) returns at once too. This is what keeps a
/// missing wake-up from hanging the whole run.
@discardableResult
func guardedAwait(
    _ what: String, limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation,
    _ work: @escaping @Sendable () async -> Void
) async -> Bool {
    let outcome = Rendezvous()
    Task {
        await work()
        outcome.finish(true)
    }
    let watchdog = Task {
        try? await ContinuousClock().sleep(for: limit)
        outcome.finish(false)
    }
    let finished = await withTaskCancellationHandler {
        await outcome.wait()
    } onCancel: {
        outcome.finish(false)
    }
    watchdog.cancel()
    if !finished && !Task.isCancelled {
        Issue.record("\(what) did not finish within \(limit)", sourceLocation: sourceLocation)
    }
    return finished
}

extension WindowEngine {
    /// `flushEvents()` that cannot hang the run.
    @discardableResult
    func flushGuarded(limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await guardedAwait("flushEvents()", limit: limit, sourceLocation: sourceLocation) { await self.flushEvents() }
    }

    /// `waitForWork()` that cannot hang the run.
    @discardableResult
    func waitForWorkGuarded(limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async
        -> Bool
    {
        await guardedAwait("waitForWork()", limit: limit, sourceLocation: sourceLocation) { await self.waitForWork() }
    }

    /// `settle()` that cannot hang the run. `settle()` waits for the flush tick too, and a tick armed by an event that
    /// reached the coalescer after the flush would sleep on a virtual clock nobody advances. `flushEvents()` first
    /// waits until the engine's pump has taken every event the client emitted (`waitForPump()`, which ends when the
    /// task is cancelled), so one flush leaves no event behind; the guard still turns any other stall into a named
    /// failure after `limit`.
    @discardableResult
    func settleGuarded(limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async -> Bool
    {
        await guardedAwait("settle()", limit: limit, sourceLocation: sourceLocation) {
            await self.flushEvents()
            await self.settle()
        }
    }
}

extension WindowsRuntime {
    /// `settle()` that cannot hang the run.
    @discardableResult
    func settleGuarded(limit: Duration = .seconds(20), sourceLocation: SourceLocation = #_sourceLocation) async -> Bool
    {
        await guardedAwait("settle()", limit: limit, sourceLocation: sourceLocation) { await self.settle() }
    }
}
