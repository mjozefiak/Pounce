import Foundation
import Testing

@testable import LintelProviders

@Suite struct ProviderGateTests {
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

    // No test here orders work with a sleep: bodies wait on latches the test fires, and "is queued" is read from the
    // gate itself. The time limit is only a guard against a hang.

    @Test(.timeLimit(.minutes(1)))
    func oneAtATimeInArrivalOrder() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let releases = (0..<5).map { _ in Latch() }
        var tasks: [Task<Void, Error>] = []
        for index in 0..<5 {
            tasks.append(
                Task {
                    try await gate.withSlot(.claudeCode) {
                        trace.begin("\(index)")
                        await releases[index].wait()
                        trace.end("\(index)")
                    }
                })
            // Arrival order is the order of submission: the previous task holds the slot or waits in the queue.
            #expect(await eventuallyAsync { await gate.queuedCount == index })
        }
        for index in 0..<5 {
            await releases[index].fire()
            try await tasks[index].value
        }
        #expect(trace.maxRunning == 1)
        #expect(trace.events == (0..<5).flatMap { ["begin \($0)", "end \($0)"] })
    }

    @Test(.timeLimit(.minutes(1)))
    func differentProvidersDoNotWaitForEachOther() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let aEntered = Latch()
        let releaseA = Latch()
        let a = Task {
            try await gate.withSlot(.claudeCode) {
                trace.begin("a")
                await aEntered.fire()
                await releaseA.wait()
                trace.end("a")
            }
        }
        await aEntered.wait()
        // `a` still holds its slot; `b` is another provider and must run to the end meanwhile.
        try await gate.withSlot(ProviderID(rawValue: "other")) {
            trace.begin("b")
            trace.end("b")
        }
        #expect(trace.events == ["begin a", "begin b", "end b"])
        await releaseA.fire()
        try await a.value
        #expect(trace.events == ["begin a", "begin b", "end b", "end a"])
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledWaiterLeavesTheQueueAndTheNextOneRuns() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let holderEntered = Latch()
        let releaseHolder = Latch()
        let holder = Task {
            try await gate.withSlot(.claudeCode) {
                await holderEntered.fire()
                await releaseHolder.wait()
            }
        }
        await holderEntered.wait()
        let cancelled = Task { try await gate.withSlot(.claudeCode) { trace.begin("cancelled") } }
        #expect(await eventuallyAsync { await gate.queuedCount == 1 })
        let next = Task { try await gate.withSlot(.claudeCode) { trace.begin("next") } }
        #expect(await eventuallyAsync { await gate.queuedCount == 2 })
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
        #expect(await gate.queuedCount == 1)
        await releaseHolder.fire()
        try await holder.value
        try await next.value
        #expect(trace.events == ["begin next"])
        #expect(await gate.queuedCount == 0)
    }

    @Test func aThrowingBodyReleasesTheSlot() async throws {
        let gate = ProviderGate()
        await #expect(throws: ProviderError.timedOut) {
            try await gate.withSlot(.claudeCode) { throw ProviderError.timedOut }
        }
        let value = try await gate.withSlot(.claudeCode) { 7 }
        #expect(value == 7)
    }
}
