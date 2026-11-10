import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// QA defect D2: the snap overlay took about 145 ms to appear, of which the engine's 30 ms coalescing tick was part.
/// The first move of a window on a workspace that offers snap targets is flushed at once; nothing else is. The clock
/// never advances here, so a report that arrives did not wait for a tick.
@Suite(.timeLimit(.minutes(1))) struct DragLatencyTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

    private func rig(kind: LayoutKind) throws -> (WindowsHarness, FakeWindowClient, WindowEngine, Box<WindowID>) {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let moved = Box<WindowID>()
        var config = EngineConfig()
        config.layout = LayoutConfig(defaultKind: kind, innerGap: 0, outerGap: 0, rootOrientation: .horizontal)
        config.zones = ZonesConfig()
        let engine = makeEngine(
            client: client, store: store, clock: VirtualClock(autoAdvance: false), config: config,
            reporter: EngineReporter(windowMoved: { id, _ in Task { await moved.set(id) } }))
        return (harness, client, engine, moved)
    }

    @Test func theFirstMoveOnAZonesWorkspaceReachesTheReducerWithoutWaitingForATick() async throws {
        let (harness, client, engine, moved) = try rig(kind: .zones)
        defer { harness.tearDown() }
        await engine.start()
        client.moveBehindTheEnginesBack(id(1), to: CGRect(x: 300, y: 300, width: 400, height: 300))
        await engine.ingest(.moved(id(1)))
        await eventually("the move was reported without a tick") { await moved.value == id(1) }
        await engine.stop()
    }

    @Test func aMoveOnAWorkspaceWithoutSnapTargetsStillWaitsForTheTick() async throws {
        let (harness, client, engine, moved) = try rig(kind: .tiling)
        defer { harness.tearDown() }
        await engine.start()
        client.moveBehindTheEnginesBack(id(1), to: CGRect(x: 300, y: 300, width: 400, height: 300))
        await engine.ingest(.moved(id(1)))
        // Nothing is running that could report it: the event waits in the coalescer for a tick that never comes.
        await engine.waitForWork()
        #expect(await moved.value == nil)
        await engine.stop()
    }

    @Test func theMovesThatFollowAreCoalescedAsBefore() async throws {
        let (harness, client, engine, moved) = try rig(kind: .zones)
        defer { harness.tearDown() }
        await engine.start()
        client.moveBehindTheEnginesBack(id(1), to: CGRect(x: 300, y: 300, width: 400, height: 300))
        await engine.ingest(.moved(id(1)))
        await eventually("the first move was reported") { await moved.value == id(1) }
        await engine.waitForWork()
        // A different window moves right after (no tick has passed): it waits for the tick, no flush storm.
        await moved.clear()
        client.moveBehindTheEnginesBack(id(2), to: CGRect(x: 320, y: 320, width: 400, height: 300))
        await engine.ingest(.moved(id(2)))
        await engine.waitForWork()
        #expect(await moved.value == nil)
        await engine.stop()
    }
}
