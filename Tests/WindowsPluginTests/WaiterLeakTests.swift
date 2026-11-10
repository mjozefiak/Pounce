import Foundation
import LintelKit
import Testing
import os

@testable import WindowsPlugin

/// Anything that waits in the plugin leaves when its caller is cancelled and when its queue ends, so nothing stays
/// parked after a timeout or after the plugin is switched off.
@Suite struct WaiterLeakTests {
    /// Lets the test hold a task until it opens the latch.
    private actor Latch {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    /// Lets other tasks run until `condition` holds; a condition that never holds fails the test instead of hanging
    /// it.
    private func eventually(_ message: String, _ condition: @Sendable () async -> Bool) async {
        for _ in 0..<200_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("never reached: \(message)")
    }

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
