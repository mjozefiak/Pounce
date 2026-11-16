import Foundation

/// Runs the asynchronous work that user actions start (a click on the strip, a button in a pane, a snap) one piece
/// after the other, in the order the actions happened, instead of as unrelated tasks that may overtake each other.
/// One task per queue, started on first use, ended by `finish()` (the runtime's stop) or when the queue is freed.
@MainActor
final class OrderedActions {
    private let continuation: AsyncStream<@MainActor () async -> Void>.Continuation
    private let stream: AsyncStream<@MainActor () async -> Void>
    private var task: Task<Void, Never>?
    private var pending = 0
    private var finished = false
    private var nextWaiter: UInt64 = 0
    private var idleWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: (@MainActor () async -> Void).self)
    }

    deinit {
        continuation.finish()
    }

    /// Queues `work` behind everything queued before it. After `finish()` nothing is queued.
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        guard !finished else { return }
        if task == nil {
            let stream = stream
            task = Task { @MainActor [weak self] in
                for await work in stream {
                    guard !Task.isCancelled else { return }
                    await work()
                    self?.finishedOne()
                }
            }
        }
        pending += 1
        continuation.yield(work)
    }

    /// Waits until everything queued so far has run (tear-down and tests). Cancelling the caller ends the wait.
    func waitUntilEmpty() async {
        if pending == 0 { return }
        nextWaiter += 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { waiter.resume() } else { idleWaiters[id] = waiter }
            }
        } onCancel: {
            Task { @MainActor in self.leave(id) }
        }
    }

    /// Ends the queue: work that has not started is dropped, the task is cancelled, every waiter is released and
    /// later `enqueue` calls do nothing.
    func finish() {
        finished = true
        continuation.finish()
        task?.cancel()
        task = nil
        pending = 0
        releaseWaiters()
    }

    #if DEBUG
    /// Whether the queue's task is still alive (tests only).
    var isRunning: Bool { task != nil }
    /// How many callers wait for the queue to empty (tests only).
    var waiterCount: Int { idleWaiters.count }
    #endif

    private func leave(_ id: UInt64) {
        idleWaiters.removeValue(forKey: id)?.resume()
    }

    private func finishedOne() {
        pending -= 1
        guard pending <= 0 else { return }
        pending = 0
        releaseWaiters()
    }

    private func releaseWaiters() {
        let waiting = idleWaiters
        idleWaiters = [:]
        for waiter in waiting.values { waiter.resume() }
    }
}
