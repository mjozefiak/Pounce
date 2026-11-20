import Foundation
import Synchronization
import Testing

@testable import LintelTestSupport

@Suite struct TestClockTests {
    private static let rounds = 100_000

    // MARK: Cancellation: every sleep ends exactly once and no cancelled sleeper stays registered

    @Test(.timeLimit(.minutes(5))) func cancelBeforeRegistration() async {
        let clock = TestClock()
        var woken = 0
        for _ in 0..<Self.rounds {
            let task = Task { await sleepEnd { try await clock.sleep(for: .seconds(1)) } }
            task.cancel()
            if await task.value == .woken { woken += 1 }
        }
        #expect(woken == 0)
        #expect(clock.sleeperCount == 0)
        #expect(clock.sleepCalls == Self.rounds)
        #expect(clock.cancelledSleeps == Self.rounds)
    }

    @Test(.timeLimit(.minutes(5))) func cancelDuringRegistration() async {
        let clock = TestClock()
        var woken = 0
        for round in 0..<Self.rounds {
            let task = Task { await sleepEnd { try await clock.sleep(for: .seconds(1)) } }
            // Vary how far the sleeper got before the cancel lands.
            if round % 3 == 1 { await Task.yield() }
            if round % 3 == 2 {
                await Task.yield()
                await Task.yield()
            }
            task.cancel()
            if await task.value == .woken { woken += 1 }
            #expect(clock.sleeperCount == 0)
        }
        #expect(woken == 0)
        #expect(clock.sleepCalls == Self.rounds)
        #expect(clock.cancelledSleeps == Self.rounds)
    }

    @Test(.timeLimit(.minutes(5))) func cancelAfterTheSleeperWasWoken() async {
        let clock = TestClock()
        for _ in 0..<Self.rounds {
            let task = Task { await sleepEnd { try await clock.sleep(for: .seconds(1)) } }
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(1))
            task.cancel()
            // Woken exactly once; a late cancel changes nothing.
            #expect(await task.value == .woken)
            #expect(clock.sleeperCount == 0)
        }
        #expect(clock.cancelledSleeps == 0)
        #expect(clock.wokenDeadlines.count == Self.rounds)
    }

    @Test func aSleepThatIsAlreadyDueReturnsAtOnce() async throws {
        let clock = TestClock(start: .seconds(10))
        try await clock.sleep(until: TestInstant(offset: .seconds(5)))
        try await clock.sleep(for: .zero)
        #expect(clock.sleeperCount == 0)
        #expect(clock.sleepCalls == 2)
    }

    // MARK: Advance

    @Test(.timeLimit(.minutes(5))) func advanceRacingNewSleepsNeverLosesOne() async {
        let clock = TestClock()
        let rounds = 20_000
        let ended = await withTaskGroup(of: SleepEnd.self) { group in
            for _ in 0..<rounds {
                group.addTask { await sleepEnd { try await clock.sleep(for: .milliseconds(1)) } }
            }
            // Advance while the sleepers are still being registered: each one either saw the new time and returned
            // at once, or was stored and is woken by a later advance.
            group.addTask {
                while clock.sleepCalls < rounds || clock.sleeperCount > 0 {
                    clock.advance(by: .milliseconds(1))
                    await Task.yield()
                }
                return .woken
            }
            var woken = 0
            for await end in group where end == .woken { woken += 1 }
            return woken
        }
        #expect(ended == rounds + 1)
        #expect(clock.sleeperCount == 0)
        #expect(clock.cancelledSleeps == 0)
    }

    @Test func advanceWakesInDeadlineOrderAndTiesInTheOrderTheyWentToSleep() async {
        let clock = TestClock()
        let order = OrderLog()
        let deadlines: [Duration] = [.seconds(5), .seconds(2), .seconds(9), .seconds(2), .seconds(1)]
        var tasks: [Task<Void, Never>] = []
        for (index, delay) in deadlines.enumerated() {
            tasks.append(
                Task {
                    try? await clock.sleep(for: delay)
                    order.append(index)
                })
            await clock.waitForSleepers(index + 1)
        }
        clock.advance(by: .seconds(10))
        for task in tasks { await task.value }
        #expect(
            clock.wokenDeadlines.map(\.offset) == [.seconds(1), .seconds(2), .seconds(2), .seconds(5), .seconds(9)])
        // The resumes are issued in deadline order; the tasks then run on the pool, so compare the wake log only.
        #expect(Set(order.values) == [0, 1, 2, 3, 4])
    }

    @Test func advanceOnlyWakesWhatIsDue() async {
        let clock = TestClock()
        let short = Task { await sleepEnd { try await clock.sleep(for: .seconds(1)) } }
        let long = Task { await sleepEnd { try await clock.sleep(for: .seconds(100)) } }
        await clock.waitForSleepers(2)
        clock.advance(by: .seconds(1))
        #expect(await short.value == .woken)
        #expect(clock.sleeperCount == 1)
        long.cancel()
        #expect(await long.value == .cancelled)
        #expect(clock.sleeperCount == 0)
    }

    // MARK: Bounded waits

    @Test func waitForSleepersIsNotSatisfiedByACancelledSleeper() async {
        let clock = TestClock()
        let task = Task { await sleepEnd { try await clock.sleep(for: .seconds(1)) } }
        await clock.waitForSleepers(1)
        task.cancel()
        _ = await task.value
        #expect(clock.sleeperCount == 0)
        #expect(await clock.waitForCancelledSleeps(1))
        let issues = await recordedIssues {
            let satisfied = await clock.waitForSleepers(1, guard: .milliseconds(50))
            #expect(!satisfied)
        }
        #expect(issues.count == 1)
    }

    @Test func waitForSleepCallsCountsEveryCall() async throws {
        let clock = TestClock()
        try await clock.sleep(for: .zero)
        let task = Task { try? await clock.sleep(for: .seconds(1)) }
        #expect(await clock.waitForSleepCalls(2))
        task.cancel()
        await task.value
    }

    @Test func anExpiredGuardNamesTheCallersLineAndLeavesNoTaskBehind() async {
        let clock = TestClock()
        var line = 0
        let issues = await recordedIssues {
            line = #line + 1
            await clock.waitForSleepers(1, guard: .milliseconds(30))
        }
        #expect(issues.count == 1)
        #expect(issues.first?.sourceLocation?.line == line)
        #expect(issues.first?.sourceLocation?.fileID.hasSuffix("TestClockTests.swift") == true)
        #expect(issues.first?.description.contains("1 sleeper(s) to be asleep") == true)
        #expect(clock.pendingWaiters + clock.liveTimers == 0)
    }

    @Test func aCancelledWaitReturnsFalseWithoutAnIssue() async {
        let clock = TestClock()
        let issues = await recordedIssues {
            let waiter = Task { await clock.waitForSleepers(1, guard: .seconds(60)) }
            await Task.yield()
            waiter.cancel()
            #expect(await waiter.value == false)
        }
        #expect(issues.isEmpty)
        #expect(clock.pendingWaiters + clock.liveTimers == 0)
    }

    // MARK: Adapters

    @Test func theAdaptersFollowTheClock() async throws {
        let clock = TestClock()
        let origin = Date(timeIntervalSinceReferenceDate: 1000)
        let date = clock.date(origin: origin)
        let base = ContinuousClock.now
        let continuous = clock.continuousNow(base: base)
        clock.advance(by: .milliseconds(1500))
        #expect(date() == origin.addingTimeInterval(1.5))
        #expect(base.duration(to: continuous()) == .milliseconds(1500))
        let sleeper = clock.sleeper
        let task = Task { await sleepEnd { try await sleeper(.seconds(2)) } }
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(2))
        #expect(await task.value == .woken)
    }
}

/// A list appended to from tasks.
final class OrderLog: Sendable {
    private let lock = Mutex<[Int]>([])
    func append(_ value: Int) { lock.withLock { $0.append(value) } }
    var values: [Int] { lock.withLock { $0 } }
}
