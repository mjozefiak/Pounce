import Foundation
import LintelTestSupport
import Testing

@testable import LintelProviders

@Suite(.timeLimit(.minutes(1))) struct ProviderGateTests {
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var events: [String] = []
        private(set) var running = 0
        private(set) var maxRunning = 0
        func begin(_ name: String) {
            lock.withLock {
                events.append("begin \(name)")
                running += 1
                maxRunning = max(maxRunning, running)
            }
        }
        func end(_ name: String) {
            lock.withLock {
                events.append("end \(name)")
                running -= 1
            }
        }
    }

    /// A task plus a latch it opens when it ends. A test waits on the latch with a guard, so a regression in the gate
    /// (a lost wake-up, a broken order, a slot never released) becomes one `Issue` on the line that waited, not a hang.
    /// The `.timeLimit` on the suite is only the last net: it cannot end a test that waits on a continuation which
    /// ignores cancellation, so every wait here answers cancellation.
    struct Job<T: Sendable>: Sendable {
        let task: Task<T, Error>
        let done: Latch

        init(_ body: @escaping @Sendable () async throws -> T) {
            let done = Latch()
            self.done = done
            task = Task {
                defer { done.open() }
                return try await body()
            }
        }

        func cancel() { task.cancel() }

        /// The task's result once it ended; `nil` (and an `Issue` at the caller's line) when it did not in time.
        func result(
            _ what: String, guard limit: Duration = .seconds(10), sourceLocation: SourceLocation = #_sourceLocation
        ) async -> Result<T, Error>? {
            guard await done.wait(guard: limit, "\(what) to end", sourceLocation: sourceLocation) else { return nil }
            return await task.result
        }
    }

    /// Waits for the gate's queue to reach `count`, read from the gate itself.
    private func queued(
        _ gate: ProviderGate, _ count: Int, _ what: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await pollUntil("the queue to hold \(count) (\(what))", guard: .seconds(10), sourceLocation: sourceLocation) {
            await gate.queuedCount == count
        }
    }

    // No test here orders work with a sleep: bodies wait on latches the test opens, and "is queued" is read from the
    // gate itself.

    @Test
    func oneAtATimeInArrivalOrder() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let entered = (0..<5).map { _ in Latch() }
        let releases = (0..<5).map { _ in Latch() }
        var jobs: [Job<Void>] = []
        func abort() { for job in jobs { job.cancel() } }
        for index in 0..<5 {
            jobs.append(
                Job {
                    try await gate.withSlot(.claudeCode) {
                        trace.begin("\(index)")
                        entered[index].open()
                        await releases[index].wait()
                        trace.end("\(index)")
                    }
                })
            // Arrival order is the order of submission: the previous task holds the slot or waits in the queue.
            guard await queued(gate, index, "task \(index) arrived") else { return abort() }
        }
        for index in 0..<5 {
            // Only the oldest waiter may be handed the slot.
            guard await entered[index].wait(guard: .seconds(10), "task \(index) to get the slot in arrival order")
            else {
                return abort()
            }
            releases[index].open()
            guard let result = await jobs[index].result("task \(index)") else { return abort() }
            try result.get()
        }
        #expect(trace.maxRunning == 1)
        #expect(trace.events == (0..<5).flatMap { ["begin \($0)", "end \($0)"] })
    }

    @Test
    func differentProvidersDoNotWaitForEachOther() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let aEntered = Latch()
        let releaseA = Latch()
        let a = Job<Void> {
            try await gate.withSlot(.claudeCode) {
                trace.begin("a")
                aEntered.open()
                await releaseA.wait()
                trace.end("a")
            }
        }
        guard await aEntered.wait(guard: .seconds(10), "a to hold its slot") else { return a.cancel() }
        // `a` still holds its slot; `b` is another provider and must run to the end meanwhile.
        let b = Job<Void> {
            try await gate.withSlot(ProviderID(rawValue: "other")) {
                trace.begin("b")
                trace.end("b")
            }
        }
        guard let bResult = await b.result("b, another provider, while a holds its slot") else {
            b.cancel()
            return a.cancel()
        }
        try bResult.get()
        #expect(trace.events == ["begin a", "begin b", "end b"])
        releaseA.open()
        guard let aResult = await a.result("a") else { return a.cancel() }
        try aResult.get()
        #expect(trace.events == ["begin a", "begin b", "end b", "end a"])
    }

    @Test
    func aCancelledWaiterLeavesTheQueueAndTheNextOneRuns() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let holderEntered = Latch()
        let releaseHolder = Latch()
        let holder = Job<Void> {
            try await gate.withSlot(.claudeCode) {
                holderEntered.open()
                await releaseHolder.wait()
            }
        }
        let cancelled = Job<Void> {
            guard await holderEntered.wait(guard: .seconds(10), "the holder to hold the slot") else { return }
            try await gate.withSlot(.claudeCode) { trace.begin("cancelled") }
        }
        let next = Job<Void> { try await gate.withSlot(.claudeCode) { trace.begin("next") } }
        func abort() { for job in [holder, cancelled, next] { job.cancel() } }
        guard await queued(gate, 2, "cancelled and next") else { return abort() }
        cancelled.cancel()
        guard let cancelledResult = await cancelled.result("the cancelled waiter") else { return abort() }
        #expect(throws: (any Error).self) { try cancelledResult.get() }
        guard await queued(gate, 1, "next, once the cancelled waiter left") else { return abort() }
        releaseHolder.open()
        guard let holderResult = await holder.result("the holder") else { return abort() }
        try holderResult.get()
        guard let nextResult = await next.result("next, once the holder released the slot") else { return abort() }
        try nextResult.get()
        #expect(trace.events == ["begin next"])
        #expect(await gate.queuedCount == 0)
    }

    @Test
    func aThrowingBodyReleasesTheSlot() async throws {
        let gate = ProviderGate()
        await #expect(throws: ProviderError.timedOut) {
            try await gate.withSlot(.claudeCode) { throw ProviderError.timedOut }
        }
        let second = Job { try await gate.withSlot(.claudeCode) { 7 } }
        guard let result = await second.result("a second run after a throwing body") else { return second.cancel() }
        #expect(try result.get() == 7)
    }
}
