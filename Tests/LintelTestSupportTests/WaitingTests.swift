import Observation
import Testing

@testable import LintelTestSupport

@Suite struct WaitingTests {
    // MARK: CountLatch

    @Test func aCountLatchWakesAWaiterWhenTheTargetIsReached() async {
        let latch = CountLatch()
        let waiter = Task { await latch.wait(atLeast: 3) }
        for _ in 0..<3 { latch.increment() }
        #expect(await waiter.value)
        #expect(latch.count == 3)
        #expect(await latch.wait(atLeast: 2), "an already-reached target returns at once")
        #expect(latch.pendingWaiters + latch.liveTimers == 0)
    }

    @Test func anExpiredCountLatchGuardRecordsOneIssueAtTheCallersLine() async {
        let latch = CountLatch()
        var line = 0
        let issues = await recordedIssues {
            line = #line + 1
            let reached = await latch.wait(atLeast: 1, guard: .milliseconds(30), "the fake to be called")
            #expect(!reached)
        }
        #expect(issues.count == 1)
        #expect(issues.first?.sourceLocation?.line == line)
        #expect(issues.first?.description.contains("the fake to be called") == true)
        #expect(latch.pendingWaiters + latch.liveTimers == 0)
    }

    // MARK: Latch

    @Test func aLatchStaysOpenAndWakesEveryWaiter() async {
        let latch = Latch()
        let waiters = (0..<5).map { _ in Task { await latch.wait() } }
        latch.open()
        for waiter in waiters { #expect(await waiter.value) }
        #expect(latch.isOpen)
        #expect(await latch.wait())
        #expect(latch.pendingWaiters + latch.liveTimers == 0)
    }

    @Test func aCancelledLatchWaitReturnsFalseWithoutAnIssue() async {
        let latch = Latch()
        let issues = await recordedIssues {
            let waiter = Task { await latch.wait() }
            await Task.yield()
            waiter.cancel()
            #expect(await waiter.value == false)
        }
        #expect(issues.isEmpty)
        #expect(latch.pendingWaiters + latch.liveTimers == 0)
    }

    @Test(.timeLimit(.minutes(5))) func cancellingWaitsInAllRacePositionsLeavesNothingBehind() async {
        let latch = Latch()
        for round in 0..<20_000 {
            let waiter = Task { await latch.wait(guard: .seconds(60)) }
            if round % 3 == 1 { await Task.yield() }
            waiter.cancel()
            #expect(await waiter.value == false)
        }
        #expect(latch.pendingWaiters + latch.liveTimers == 0)
    }

    // MARK: ChangeBell

    @Test func aChangeBellRechecksAfterEveryRing() async {
        let bell = ChangeBell()
        let flag = Latch()
        let waiter = Task { await bell.wait { flag.isOpen } }
        await Task.yield()
        flag.open()
        bell.ring()
        #expect(await waiter.value)
    }

    @Test func aRingNobodyWaitedForIsNotLost() async {
        let bell = ChangeBell()
        let flag = Latch()
        flag.open()
        bell.ring()
        #expect(await bell.wait { flag.isOpen })
    }

    @Test func anExpiredBellGuardRecordsOneIssueAtTheCallersLine() async {
        let bell = ChangeBell()
        var line = 0
        let issues = await recordedIssues {
            line = #line + 1
            let satisfied = await bell.wait(guard: .milliseconds(30), "never") { false }
            #expect(!satisfied)
        }
        #expect(issues.count == 1)
        #expect(issues.first?.sourceLocation?.line == line)
    }

    // MARK: waitForObserved

    @Observable @MainActor final class Model {
        var value = 0
    }

    @MainActor @Test func waitForObservedSeesAChangeMadeLater() async {
        let model = Model()
        Task { @MainActor in
            await Task.yield()
            model.value = 1
            await Task.yield()
            model.value = 2
        }
        #expect(await waitForObserved("the value to reach 2") { model.value == 2 })
    }

    @MainActor @Test func waitForObservedReturnsAtOnceWhenAlreadyTrue() async {
        let model = Model()
        #expect(await waitForObserved("zero") { model.value == 0 })
    }

    @MainActor @Test func anExpiredObservedGuardRecordsOneIssueAtTheCallersLine() async {
        let model = Model()
        var line = 0
        let issues = await recordedIssues {
            line = #line + 1
            let seen = await waitForObserved("the value to change", guard: .milliseconds(30)) { model.value == 9 }
            #expect(!seen)
        }
        #expect(issues.count == 1)
        #expect(issues.first?.sourceLocation?.line == line)
    }

    // MARK: pollUntil

    @Test func pollUntilReturnsWhenTheConditionHolds() async {
        let counter = CountLatch()
        #expect(await pollUntil("three polls", every: .milliseconds(1)) { counter.increment() >= 3 })
    }

    @Test func anExpiredPollRecordsOneIssueAtTheCallersLine() async {
        var line = 0
        let issues = await recordedIssues {
            line = #line + 1
            let held = await pollUntil("never", guard: .milliseconds(30), every: .milliseconds(5)) { false }
            #expect(!held)
        }
        #expect(issues.count == 1)
        #expect(issues.first?.sourceLocation?.line == line)
    }

    @Test func aCancelledPollStopsWithoutAnIssue() async {
        let issues = await recordedIssues {
            let poll = Task { await pollUntil("never", guard: .seconds(60), every: .milliseconds(5)) { false } }
            await Task.yield()
            poll.cancel()
            #expect(await poll.value == false)
        }
        #expect(issues.isEmpty)
    }

    // MARK: ImmediateClock and NeverClock

    @Test func anImmediateClockEndsSleepsAtOnceAndRecordsThem() async throws {
        let clock = ImmediateClock()
        try await clock.sleep(for: .seconds(3600))
        try await clock.sleep(for: .seconds(2))
        #expect(clock.sleptDurations == [.seconds(3600), .seconds(2)])
        #expect(clock.now.offset == .seconds(3602))
    }

    @Test func anImmediateClockStillThrowsWhenCancelled() async {
        let clock = ImmediateClock()
        let task = Task { await sleepEnd { try await clock.sleep(for: .seconds(1)) } }
        task.cancel()
        #expect(await task.value == .cancelled)
    }

    @Test func theSpinGuardStopsALoopThatSleepsWithoutEndAndReportsOnce() async {
        let clock = ImmediateClock(maxSleeps: 50)
        let issues = await recordedIssues {
            var calls = 0
            while (try? await clock.sleep(for: .milliseconds(1))) != nil, calls < 10_000 { calls += 1 }
            #expect(calls == 50)
        }
        #expect(issues.count == 1)
    }

    @Test func aNeverClockEndsOnlyByCancellationAndLeavesNothingRegistered() async {
        let clock = NeverClock()
        let task = Task { await sleepEnd { try await clock.sleep(for: .seconds(24 * 3600)) } }
        #expect(await clock.waitForSleepers(1))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(clock.sleeperCount == 0)
    }
}
