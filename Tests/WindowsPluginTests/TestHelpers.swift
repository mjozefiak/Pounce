import Foundation
import Testing

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
