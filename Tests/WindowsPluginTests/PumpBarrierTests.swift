import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The engine's pump takes the client's events on its own schedule. `flushEvents()` waits for it to have taken what the
/// client had emitted, so an event emitted before the flush is never left for a flush tick that a virtual clock does
/// not fire (issue #123).
@Suite(.timeLimit(.minutes(2))) struct PumpBarrierTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

    private func engine(client: FakeWindowClient, harness: WindowsHarness) -> WindowEngine {
        makeEngine(
            client: client, store: StateStore(directory: harness.directory, saveDelay: .seconds(3600)),
            clock: VirtualClock(autoAdvance: false), workspaceCount: 4, tick: .seconds(3600))
    }

    @Test func oneFlushAfterAnEmitLeavesNoEventForTheTick() async throws {
        let rounds = 300
        var late = 0
        for _ in 0..<rounds {
            let harness = try WindowsHarness()
            defer { harness.tearDown() }
            let client = FakeWindowClient(windows: [makeWindow(1)])
            let engine = engine(client: client, harness: harness)
            await engine.start()
            client.emit([.moved(id(1)), .resized(id(1))])
            await engine.flushEvents()
            // The settle ends only when no event waits for the tick; a late event would keep it for ever, so the
            // wait is bounded by the clock below and by the caller's cancellation.
            let settled = await guardedAwait("settle()", limit: .seconds(3)) { await engine.settle() }
            if !settled { late += 1 }
            await engine.stop()
        }
        #expect(late == 0, "\(late) of \(rounds) rounds left an event for the flush tick")
    }

    @Test func theBarrierEndsWhenTheCallerIsCancelled() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let engine = engine(client: client, harness: harness)
        await engine.start()
        await engine.stop()
        // The engine is stopped: the barrier returns at once and nothing waits.
        client.emit([.moved(id(1))])
        let finished = await guardedAwait("waitForPump()", limit: .seconds(5)) { await engine.waitForPump() }
        #expect(finished)
    }

    @Test func theBarrierEndsWhenTheStreamFinishes() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let engine = engine(client: client, harness: harness)
        await engine.start()
        client.finish()
        client.emit([.moved(id(1))])
        let finished = await guardedAwait("waitForPump()", limit: .seconds(5)) { await engine.waitForPump() }
        #expect(finished)
        await engine.stop()
    }
}
