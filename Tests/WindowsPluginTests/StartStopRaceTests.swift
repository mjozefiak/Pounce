import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// A start that is still running when a stop (the host's activation budget, a disable, a re-grant check) comes:
/// the start ends at its next step, takes nothing that nobody ends, and cannot revive what was stopped.
@Suite struct StartStopRaceTests {
    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let plugin: WindowsPlugin
    }

    @MainActor private func rig() throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(
                windows: client, permissions: ScriptedPermissions(granted: true),
                clock: VirtualClock(autoAdvance: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        return Rig(harness: harness, client: client, plugin: plugin)
    }

    @MainActor @Test func aStopDuringAStuckStartEndsTheStartAndLeavesNothingBehind() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        rig.client.armSnapshotHold()
        let start = Task { try await rig.plugin.activate() }
        await rig.client.waitUntilReadHeld()

        // The host's budget ran out: it deactivates while the start is still suspended in the engine.
        await rig.plugin.deactivate()
        rig.client.releaseReadHold()
        let result = await start.result
        guard case .failure(let error) = result, error is CancellationError else {
            Issue.record("the overtaken start should end with a CancellationError, got \(result)")
            return
        }
        #expect(rig.plugin.runtime == nil)
        #expect(rig.plugin.lastStartError == nil)
        await rig.plugin.journal.waitUntilIdle()
        #expect(await rig.plugin.journal.phase == .idle)
        #expect(rig.client.eventsTerminated)
        // The late start moved nothing and hid nothing.
        #expect(rig.client.calls.isEmpty)
        #expect(await rig.plugin.journal.store.hidden.isEmpty)
        // The plugin can be started again afterwards.
        try await rig.plugin.activate()
        #expect(rig.plugin.runtime != nil)
        await rig.plugin.deactivate()
    }

    @MainActor @Test func aCancelledStartEndsItselfAndFreesTheJournal() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        rig.client.armSnapshotHold()
        let start = Task { try await rig.plugin.activate() }
        await rig.client.waitUntilReadHeld()
        start.cancel()
        rig.client.releaseReadHold()
        let result = await start.result
        guard case .failure(let error) = result, error is CancellationError else {
            Issue.record("a cancelled start should throw CancellationError, got \(result)")
            return
        }
        #expect(rig.plugin.runtime == nil)
        await rig.plugin.journal.waitUntilIdle()
        #expect(await rig.plugin.journal.phase == .idle)
        #expect(rig.client.eventsTerminated)
    }

    @MainActor @Test func aStopWhileTheStartWaitsForTheJournalLeavesNoLeaseNobodyEnds() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        // The clock stays still: the start's wait for the journal lasts until the journal is handed back.
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        let earlier = try #require(await plugin.journal.tryBeginEngine())
        let start = Task { try await plugin.activate() }
        await harness.clock.waitForSleepers(1)

        await plugin.deactivate()
        await plugin.journal.endEngine(earlier)
        let result = await start.result
        guard case .failure(let error) = result, error is CancellationError else {
            Issue.record("the overtaken start should end with a CancellationError, got \(result)")
            return
        }
        // The start took the journal after the stop (the earlier engine had ended) and handed that lease back
        // itself: the earlier lease was 1, the late one 2, so the next one is 3.
        #expect(await plugin.journal.phase == .idle)
        #expect(await plugin.journal.tryBeginEngine() == 3)
        #expect(plugin.runtime == nil)
        #expect(client.callLog.contains("subscribe") == false)
    }

    @MainActor @Test func aSelfCheckThatFailsDuringTheStartKeepsItsReasonAndEndsTheStart() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        rig.client.armSnapshotHold()
        let start = Task { try await rig.plugin.activate() }
        await rig.client.waitUntilReadHeld()
        // Accessibility was re-granted and the self-check now fails: it stops the runtime from inside the start.
        rig.client.setAvailable(false)
        await rig.plugin.recheckAvailability()
        rig.client.releaseReadHold()
        _ = await start.result
        #expect(rig.plugin.lastStartError == .unsupported(reason: "scripted"))
        #expect(rig.plugin.runtime == nil)
        await rig.plugin.journal.waitUntilIdle()
        #expect(await rig.plugin.journal.phase == .idle)
    }

    @Test func anEngineThatWasStoppedStaysStoppedWhenAStartComesLate() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let store = StateStore(directory: harness.directory)
        let engine = makeEngine(client: client, store: store, clock: VirtualClock())
        await engine.stop()
        await engine.start()
        #expect(client.callLog.contains("subscribe") == false)
        #expect(client.callLog.contains("windows") == false)
    }

    @Test func aStopDuringTheEnginesStartDropsTheSubscription() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let store = StateStore(directory: harness.directory)
        let engine = makeEngine(client: client, store: store, clock: VirtualClock())
        client.armSnapshotHold()
        let start = Task { await engine.start() }
        await client.waitUntilReadHeld()
        await engine.stop()
        client.releaseReadHold()
        await start.value
        #expect(client.eventsTerminated)
    }
}
