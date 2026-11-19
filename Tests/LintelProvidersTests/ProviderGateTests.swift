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

    @Test func oneAtATimeInArrivalOrder() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        var tasks: [Task<Void, Error>] = []
        for index in 0..<5 {
            tasks.append(
                Task {
                    try await gate.withSlot(.claudeCode) {
                        trace.begin("\(index)")
                        try await Task.sleep(for: .milliseconds(30))
                        trace.end("\(index)")
                    }
                })
            try await Task.sleep(for: .milliseconds(15))  // arrival order is the order of submission
        }
        for task in tasks { try await task.value }
        #expect(trace.maxRunning == 1)
        #expect(trace.events == (0..<5).flatMap { ["begin \($0)", "end \($0)"] })
    }

    @Test func differentProvidersDoNotWaitForEachOther() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        async let a: Void = gate.withSlot(.claudeCode) {
            trace.begin("a")
            try await Task.sleep(for: .milliseconds(150))
            trace.end("a")
        }
        try await Task.sleep(for: .milliseconds(30))
        async let b: Void = gate.withSlot(ProviderID(rawValue: "other")) {
            trace.begin("b")
            trace.end("b")
        }
        _ = try await (a, b)
        #expect(trace.events.first == "begin a" && trace.events[1] == "begin b")
    }

    @Test func aCancelledWaiterLeavesTheQueueAndTheNextOneRuns() async throws {
        let gate = ProviderGate()
        let trace = Trace()
        let holder = Task {
            try await gate.withSlot(.claudeCode) { try await Task.sleep(for: .milliseconds(300)) }
        }
        try await Task.sleep(for: .milliseconds(50))
        let cancelled = Task { try await gate.withSlot(.claudeCode) { trace.begin("cancelled") } }
        let next = Task { try await gate.withSlot(.claudeCode) { trace.begin("next") } }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await #expect(throws: (any Error).self) { try await cancelled.value }
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
