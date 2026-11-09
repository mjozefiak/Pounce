import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// How events reach the engine: strictly in order, subscribed before the snapshot, and nothing after `stop()`.
@Suite struct EventFlowTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let store: StateStore
        let engine: WindowEngine
    }

    /// A tick that never fires on its own: the test flushes by hand.
    private func rig(_ windows: [WindowInfo]) throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: windows)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let engine = makeEngine(
            client: client, store: store, clock: VirtualClock(autoAdvance: false), workspaceCount: 4,
            tick: .seconds(3600))
        return Rig(harness: harness, client: client, store: store, engine: engine)
    }

    @Test func twoFlushesNeverOverlapSoAStaleMoveCannotFollowTheDestroy() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        // The first flush has read the window and waits for its answer to arrive.
        rig.client.armReadHold()
        await rig.engine.ingest(.moved(id(1)))
        let first = Task { await rig.engine.flushEvents() }
        await rig.client.waitUntilReadHeld()
        // The window is closed meanwhile and a second flush starts: it must wait for the first.
        rig.client.remove(id(1))
        await rig.engine.ingest(.destroyed(id(1)))
        let second = Task { await rig.engine.flushEvents() }
        rig.client.releaseReadHold()
        await first.value
        await second.value
        // The move was reduced first and the destroy after it: no ghost window is left behind.
        #expect(await rig.engine.snapshot.windows.isEmpty)
        await rig.engine.stop()
    }

    @Test func theEngineSubscribesBeforeItTakesTheSnapshot() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        let log = rig.client.callLog
        let subscribed = try #require(log.firstIndex(of: "subscribe"))
        let snapshot = try #require(log.firstIndex(of: "windows"))
        #expect(subscribed < snapshot)
        await rig.engine.stop()
    }

    @Test func anEventThatArrivesWhileTheSnapshotIsReadIsFlushedAfterIt() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        // The window goes while the engine is starting; its event is already in the stream.
        rig.client.emit([.destroyed(id(1))])
        rig.client.remove(id(1))
        await rig.engine.start()
        await rig.engine.flushEvents()
        #expect(await rig.engine.snapshot.windows.isEmpty)
        await rig.engine.stop()
    }

    @Test func afterStopNothingIsAcceptedAndNothingMoves() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.stop()
        rig.client.clearCalls()
        // Returns at once: no hang, no frame change, no write to the closed store.
        await rig.engine.send(.showWorkspace(ws(2)))
        await rig.engine.update(config: EngineConfig())
        await rig.engine.ingest(.created(id(9)))
        await rig.engine.flushEvents()
        #expect(rig.client.calls.isEmpty)
        #expect(await rig.engine.restoreAllWindows().isEmpty)
    }
}
