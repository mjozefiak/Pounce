import Foundation

/// Runs the asynchronous work that user actions start (a click on the strip, a button in a pane, a snap) one piece
/// after the other, in the order the actions happened, instead of as unrelated tasks that may overtake each other.
/// One task per queue, started on first use.
@MainActor
final class OrderedActions {
    private let continuation: AsyncStream<@MainActor () async -> Void>.Continuation
    private let stream: AsyncStream<@MainActor () async -> Void>
    private var task: Task<Void, Never>?
    private var pending = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: (@MainActor () async -> Void).self)
    }

    /// Queues `work` behind everything queued before it.
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        if task == nil {
            let stream = stream
            task = Task { @MainActor [weak self] in
                for await work in stream {
                    await work()
                    self?.finishedOne()
                }
            }
        }
        pending += 1
        continuation.yield(work)
    }

    /// Waits until everything queued so far has run (tear-down and tests).
    func waitUntilEmpty() async {
        if pending == 0 { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func finishedOne() {
        pending -= 1
        guard pending == 0 else { return }
        let waiting = idleWaiters
        idleWaiters = []
        for waiter in waiting { waiter.resume() }
    }
}
