import Foundation
import LintelCore
import LintelKit
import Testing

@testable import WindowsPlugin

/// Stopping the engine while events wait for the next tick (a busy app moves windows all the time).
@Suite(.timeLimit(.minutes(1))) struct EngineStopTests {
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
        // The engine's clock is virtual and stands still: a stop that waited for the tick would never return.
        await engine.stop()
        #expect(rig.client.eventsTerminated)
    }

    @Test func aSettleIsReleasedWhenTheEventsAreFlushedByHand() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        let engine = rig.engine
        await engine.start()
        await engine.ingest(.moved(WindowID(pid: 100, number: 1)))
        // Whichever of the two comes first, the tick never comes (virtual clock): the flush by hand ends the wait.
        let waiting = Task { await engine.settle() }
        await engine.flushEvents()
        await waiting.value
        await engine.stop()
    }

    @Test func aCommandReturnsAfterItsBudgetWhileAnAppStallsAndTheWorkGoesOn() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let hung = makeWindow(1, pid: 100)
        let client = FakeWindowClient(windows: [hung, makeWindow(2, pid: 200)])
        client.setBehavior(.stall, forProcess: 100)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        // The bound runs on the engine's own clock, which only the test moves.
        let clock = VirtualClock(autoAdvance: false)
        let engine = makeEngine(
            client: client, store: store, clock: clock, workspaceCount: 4, tick: .milliseconds(5),
            commandBudget: .seconds(2))
        await engine.start()
        let hide = Task { await engine.send(.showWorkspace(WorkspaceID(2)!)) }
        await client.waitUntilStalled(1)
        await clock.waitForSleepers(1)
        // The call waits for the stalled app and nothing else can end it.
        #expect(await engine.waitingCallers() == 1)
        clock.advance(2)
        await hide.value
        // The bound fired: the call left nothing behind, and the batch itself is still running.
        #expect(await engine.waitingCallers() == 0)
        #expect(!(await store.hidden.isEmpty))
        // The abandoned work is still running and finishes once the app answers; nothing is left parked.
        client.releaseStalls()
        await engine.settle()
        await engine.stop()
        #expect(await store.hidden.isEmpty)
    }
}
