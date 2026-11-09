import Foundation
import LintelCore
import LintelKit
import Testing

@testable import WindowsPlugin

/// Stopping the engine while events wait for the next tick (a busy app moves windows all the time).
@Suite struct EngineStopTests {
    private func rig() throws -> (harness: WindowsHarness, client: FakeWindowClient, engine: WindowEngine) {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        // A clock that never advances: the tick sleep is still waiting when the engine is stopped.
        let engine = makeEngine(
            client: client, store: store, clock: VirtualClock(autoAdvance: false), tick: .milliseconds(30))
        return (harness, client, engine)
    }

    @Test func stopReturnsWhileAnEventIsWaitingForTheTick() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        let engine = rig.engine
        await engine.start()
        await engine.ingest(.moved(WindowID(pid: 100, number: 1)))
        // Real time bounds the wait: the engine's own clock is virtual and stands still.
        let finished = await withDeadline(.seconds(3), clock: ContinuousClock()) { await engine.stop() }
        #expect(finished != nil)
    }

    @Test func aSettleThatWaitsForTheTickIsReleasedWhenTheEventsAreFlushedByHand() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        let engine = rig.engine
        await engine.start()
        await engine.ingest(.moved(WindowID(pid: 100, number: 1)))
        let waiting = Task { await engine.settle() }
        // The settle must be waiting for the tick before the events are flushed by hand.
        await Task.yield()
        await engine.flushEvents()
        let finished = await withDeadline(.seconds(10), clock: ContinuousClock()) { await waiting.value }
        #expect(finished != nil)
        await engine.stop()
    }

    @Test func aCommandReturnsAfterItsBudgetWhileAnAppStallsAndTheWorkGoesOn() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let hung = makeWindow(1, pid: 100)
        let client = FakeWindowClient(windows: [hung, makeWindow(2, pid: 200)])
        client.setBehavior(.stall, forProcess: 100)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        // The budget is real time (a bound on waiting for apps); the engine's own clock is virtual.
        let engine = makeEngine(
            client: client, store: store, clock: VirtualClock(), workspaceCount: 4, tick: .milliseconds(5),
            commandBudget: .milliseconds(50))
        await engine.start()
        let hide = Task { await engine.send(.showWorkspace(WorkspaceID(2)!)) }
        await client.waitUntilStalled(1)
        // The stalled call is not released, so only the budget can end the command.
        let returned = await withDeadline(.seconds(10), clock: ContinuousClock()) { await hide.value }
        #expect(returned != nil)
        // The abandoned work is still running and finishes once the app answers; nothing is left parked.
        client.releaseStalls()
        await engine.settle()
        await engine.stop()
        #expect(await store.hidden.isEmpty)
    }
}
