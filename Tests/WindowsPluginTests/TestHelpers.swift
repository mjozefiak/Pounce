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

/// Lets other tasks run until `condition` holds; a condition that never holds fails the test instead of hanging it.
/// (Every suite that waits also has a time limit, so a wait that cannot end fails there too.)
func eventually(_ message: String, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<200_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("never reached: \(message)")
}
