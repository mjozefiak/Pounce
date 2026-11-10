import Foundation
import Synchronization

/// One serial queue per process (spec: Architecture, "Concurrency model"): work for one app runs in order, so two
/// writes to one app never interleave, while work for different apps runs in parallel and a hung app delays only
/// itself. The Accessibility calls are blocking, so they run on these queues, not on the cooperative pool.
nonisolated final class PerProcessQueues: Sendable {
    private let queues = Mutex<[Int32: DispatchQueue]>([:])

    /// Runs `work` after everything submitted earlier for `pid` has finished and returns its result.
    func run<Result: Sendable>(pid: Int32, _ work: @escaping @Sendable () -> Result) async -> Result {
        await withCheckedContinuation { continuation in
            enqueue(pid: pid) { continuation.resume(returning: work()) }
        }
    }

    /// Submits `work` and returns at once; submissions for one `pid` run strictly in the order of these calls.
    func enqueue(pid: Int32, _ work: @escaping @Sendable () -> Void) {
        queue(for: pid).async(execute: work)
    }

    /// Forgets the queue of a process that exited.
    func forget(pid: Int32) {
        queues.withLock { _ = $0.removeValue(forKey: pid) }
    }

    var count: Int { queues.withLock { $0.count } }

    private func queue(for pid: Int32) -> DispatchQueue {
        queues.withLock { queues in
            if let existing = queues[pid] { return existing }
            let queue = DispatchQueue(label: "com.lintelapp.windows.ax.\(pid)", qos: .userInitiated)
            queues[pid] = queue
            return queue
        }
    }
}
