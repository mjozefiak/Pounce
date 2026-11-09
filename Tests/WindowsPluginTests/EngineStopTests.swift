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
        let engine = WindowEngine(
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
}
