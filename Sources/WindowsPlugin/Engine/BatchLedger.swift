import Foundation

/// Counts the work each reduction handed to the executor and tells who is waiting when it has all finished. A batch
/// caused by the results of another one (`parents`) holds that one open until it is finished itself, so a caller of
/// `send` is released only when everything its input set in motion has run.
struct BatchLedger {
    private struct Batch {
        var remaining = 0
        var waiters: [@Sendable () -> Void] = []
        var parents: [Int] = []
    }

    private var batches: [Int: Batch] = [:]
    private var next = 0

    /// The id the next `open` will return.
    var peekNextID: Int { next + 1 }

    /// Opens a batch with `operations` pieces of work. Returns its id; it is closed (and its waiters released) once
    /// every piece finished, or at once when there is none.
    mutating func open(operations: Int, waiters: [@Sendable () -> Void], parents: [Int]) -> Int {
        next += 1
        batches[next] = Batch(remaining: operations, waiters: waiters, parents: parents)
        return next
    }

    /// An input caused by `parent`: the parent stays open until what the input causes has run.
    mutating func hold(_ parent: Int) {
        batches[parent]?.remaining += 1
    }

    /// One piece of work of the batch finished.
    mutating func finish(_ id: Int) {
        batches[id]?.remaining -= 1
        closeIfFinished(id)
    }

    mutating func closeIfFinished(_ id: Int) {
        guard let batch = batches[id], batch.remaining <= 0 else { return }
        batches[id] = nil
        for waiter in batch.waiters { waiter() }
        // The batches whose results caused this one were held open until now.
        for parent in batch.parents { finish(parent) }
    }
}
