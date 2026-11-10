import Foundation
import LintelKit
import Testing
import os

@testable import WindowsPlugin

/// Anything that waits in the plugin leaves when its caller is cancelled and when its queue ends, so nothing stays
/// parked after a timeout or after the plugin is switched off.
@Suite(.timeLimit(.minutes(1))) struct WaiterLeakTests {
    private func waitersOf(_ owner: JournalOwner, atLeast count: Int) async {
        await eventually("\(count) waiters on the journal") { await owner.waiterCount >= count }
    }

    @Test func aCancelledWaitForTheJournalLeavesTheQueue() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(directory: harness.directory, logger: .init())
        let lease = try #require(await owner.tryBeginEngine())
        let waiting = Task { await owner.waitUntilIdle() }
        await waitersOf(owner, atLeast: 1)
        waiting.cancel()
        await waiting.value
        #expect(await owner.waiterCount == 0)
        // The journal itself is unchanged: still the engine's.
        #expect(await owner.phase == .engine)
        await owner.endEngine(lease)
    }

    @Test func aWaitThatTimesOutLeavesNoWaiterBehind() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(directory: harness.directory, logger: .init())
        let lease = try #require(await owner.tryBeginEngine())
        // The clock stands still until the test moves it, so the waiter is parked before the budget is over.
        let clock = VirtualClock(autoAdvance: false)
        let waiting = Task { await owner.waitUntilIdle(within: .seconds(5), clock: clock) }
        await waitersOf(owner, atLeast: 1)
        await clock.waitForSleepers(1)
        clock.advance(5)
        #expect(await waiting.value == false)
        // The wait that gave up is gone from the queue, not parked until the journal is next idle.
        #expect(await owner.waiterCount == 0)
        await owner.endEngine(lease)
        #expect(await owner.waitUntilIdle(within: .seconds(5), clock: VirtualClock(autoAdvance: true)))
    }

    @Test func aPassThatWaitedRunsItsWholeBodyEvenWhenTheBudgetPassesMeanwhile() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(directory: harness.directory, logger: .init())
        let first = Latch()
        let second = Latch()
        let running = Task { await owner.exclusive { _ in await first.wait() } }
        await eventually("the first pass is running") { await owner.phase == .recovering }
        let clock = VirtualClock(autoAdvance: false)
        let waiting = Task {
            await owner.exclusive(within: .seconds(5), clock: clock) { _ -> Int in
                await second.wait()
                return 42
            }
        }
        await waitersOf(owner, atLeast: 1)
        await first.release()
        _ = await running.value
        // The wait is over and the body is running; the budget passes now, and the answer is still the body's.
        await eventually("the second pass is running") { await owner.phase == .recovering }
        clock.advance(100)
        await second.release()
        guard case .ran(let value) = await waiting.value else {
            Issue.record("a pass that got its turn must run to the end")
            return
        }
        #expect(value == 42)
        #expect(await owner.waiterCount == 0)
    }

    @Test func aPassThatWaitsLongerThanTheBudgetRunsNothingAndLeavesTheQueue() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(directory: harness.directory, logger: .init())
        let first = Latch()
        let running = Task { await owner.exclusive { _ in await first.wait() } }
        await eventually("the first pass is running") { await owner.phase == .recovering }
        let clock = VirtualClock(autoAdvance: false)
        let ran = Latch()
        let waiting = Task {
            await owner.exclusive(within: .seconds(5), clock: clock) { _ in await ran.release() }
        }
        await waitersOf(owner, atLeast: 1)
        await clock.waitForSleepers(1)
        clock.advance(5)
        guard case .cancelled = await waiting.value else {
            Issue.record("a pass that waited past its budget must answer .cancelled")
            return
        }
        #expect(await owner.waiterCount == 0)
        await first.release()
        _ = await running.value
        // Its body never ran: the latch it would have opened is still closed.
        #expect(await !ran.isOpen)
    }

    @Test func aCancelledPassWaitingForAnotherPassRunsNothing() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(directory: harness.directory, logger: .init())
        let latch = Latch()
        let first = Task { await owner.exclusive { _ in await latch.wait() } }
        await eventually("the first pass is running") { await owner.phase == .recovering }
        let second = Task { await owner.exclusive { _ in 1 } }
        await waitersOf(owner, atLeast: 1)
        second.cancel()
        guard case .cancelled = await second.value else {
            Issue.record("a cancelled waiting pass should not run")
            return
        }
        #expect(await owner.waiterCount == 0)
        await latch.release()
        _ = await first.value
        #expect(await owner.phase == .idle)
    }

    @MainActor @Test func aCancelledWaitForTheQueueLeavesItAndFinishReleasesTheRest() async {
        let actions = OrderedActions()
        let latch = Latch()
        actions.enqueue { await latch.wait() }
        let cancelled = Task { await actions.waitUntilEmpty() }
        let released = Task { await actions.waitUntilEmpty() }
        var attempts = 0
        while actions.waiterCount < 2, attempts < 200_000 {
            attempts += 1
            await Task.yield()
        }
        #expect(actions.waiterCount >= 2, "never reached: two waiters on the queue")
        cancelled.cancel()
        await cancelled.value
        #expect(actions.waiterCount == 1)

        // The queue ends with the plugin: the other waiter is released, the task is gone, later work is dropped.
        actions.finish()
        await released.value
        #expect(actions.waiterCount == 0)
        #expect(!actions.isRunning)
        var ran = false
        actions.enqueue { ran = true }
        await actions.waitUntilEmpty()
        #expect(!ran)
        await latch.release()
    }

    @MainActor @Test func nothingIsHandledAfterThePumpFinishes() async {
        var handled = 0
        let pump = ReportPump { _ in handled += 1 }
        pump.reporter.hud(WorkspaceID(1)!, 1)
        await pump.waitUntilHandled()
        #expect(handled == 1)
        // Reported before the finish but not yet handled, and reported after it: neither is delivered.
        pump.reporter.hud(WorkspaceID(1)!, 2)
        pump.finish()
        pump.reporter.hud(WorkspaceID(1)!, 3)
        await pump.waitUntilHandled()
        #expect(handled == 1)
    }
}
