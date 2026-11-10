import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// What happens when an app does not answer while the plugin is switched off: the stop budget runs out, the old
/// engine still holds the journal, and nothing may erase, restart or pretend to restore beside it.
@Suite struct StopBudgetTests {
    private let home = CGRect(x: 100, y: 100, width: 800, height: 600)
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let hud: RecordingHUD
        let plugin: WindowsPlugin
    }

    /// A plugin whose clock jumps to each deadline, so every budget is over as soon as it is awaited, and one app
    /// that stalls its first frame change until the test lets it go.
    @MainActor private func rig(granted: Bool = true) async throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(
                windows: client, permissions: ScriptedPermissions(granted: granted),
                clock: VirtualClock(autoAdvance: true)),
            hud: hud, activationCenter: NotificationCenter())
        try await plugin.activate()
        return Rig(harness: harness, client: client, hud: hud, plugin: plugin)
    }

    @MainActor @Test func aHungAppAtDisableKeepsTheJournalAndBlocksEraseRestoreAndRestart() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        let runtime = try #require(rig.plugin.runtime)
        rig.client.setBehavior(.stall, forProcess: 100)
        let hide = Task { await runtime.engine.send(.showWorkspace(ws(2))) }
        await rig.client.waitUntilStalled(1)

        // The stop budget is over at once; the engine is still stopping and still holds the journal.
        await rig.plugin.deactivate()
        #expect(rig.plugin.runtime == nil)
        #expect(await rig.plugin.journal.phase == .stopping)

        // Erase Data refuses instead of letting the host delete the journal that can put the window back.
        await #expect(throws: WindowsPlugin.EraseRefused.self) { try await rig.plugin.eraseData() }
        #expect(!(await rig.plugin.journal.store.hidden.isEmpty))

        // Restore all windows says why nothing happened instead of "0 restored".
        await rig.plugin.restoreAllWindows()
        #expect(rig.hud.shown.last == .stillStopping)

        // A re-enable cannot hang: it fails with a message that Try Again clears.
        await #expect(throws: WindowsPlugin.StartError.stillStopping) { try await rig.plugin.activate() }
        #expect(rig.plugin.lastStartError == .stillStopping)
        #expect(rig.plugin.runtime == nil)

        // The app answers; the old engine finishes and hands the journal back; now everything works again.
        rig.client.releaseStalls()
        await hide.value
        await rig.plugin.journal.waitUntilIdle()
        #expect(rig.client.frame(of: id(1)) == home)
        try await rig.plugin.activate()
        #expect(rig.plugin.lastStartError == nil)
        await rig.plugin.deactivate()
        // The clock jumps over every budget, so the stop may still be running: wait for it to hand the journal back.
        await rig.plugin.journal.waitUntilIdle()
        try await rig.plugin.eraseData()
    }

    /// A re-enable that gives up because the old engine still holds the journal must leave that engine alone: its
    /// own tear-down may not close the shared store or restore from the journal beside the old engine.
    @MainActor @Test func aRefusedReEnableDoesNotTouchTheJournalOfTheEngineThatIsStillStopping() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        let runtime = try #require(rig.plugin.runtime)
        rig.client.setBehavior(.stall, forProcess: 100)
        let hide = Task { await runtime.engine.send(.showWorkspace(ws(2))) }
        await rig.client.waitUntilStalled(1)
        await rig.plugin.deactivate()
        #expect(await rig.plugin.journal.phase == .stopping)
        let framesBefore = rig.client.calls.count

        await #expect(throws: WindowsPlugin.StartError.stillStopping) { try await rig.plugin.activate() }
        // Nothing of the refused start reached the client: it never held the journal.
        #expect(rig.client.calls.count == framesBefore)

        rig.client.releaseStalls()
        await hide.value
        await rig.plugin.journal.waitUntilIdle()
        // The old engine put the window back and could clear its journal entry: the store was still open for it.
        #expect(rig.client.frame(of: id(1)) == home)
        #expect(await rig.plugin.journal.store.hidden.isEmpty)
    }

    @MainActor @Test func restoreAllWindowsReportsWhatIsStillParkedWhenTheBudgetRunsOut() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        let runtime = try #require(rig.plugin.runtime)
        // The first window parks; then its app stops answering.
        await runtime.engine.send(.showWorkspace(ws(2)))
        rig.client.setBehavior(.stall, forProcess: 100)
        let restore = Task { await runtime.restoreAllWindows() }
        await rig.client.waitUntilStalled(1)
        await restore.value
        #expect(rig.hud.shown.last == .restored(restored: 0, onAnotherSpace: 0, failed: 1))
        rig.client.releaseStalls()
        await rig.plugin.deactivate()
    }

    @MainActor @Test func resetStateKeepsTheJournalWhileAWindowIsStillParked() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        let runtime = try #require(rig.plugin.runtime)
        await runtime.engine.send(.showWorkspace(ws(2)))
        #expect(!(await rig.plugin.journal.store.hidden.isEmpty))
        rig.client.setBehavior(.stall, forProcess: 100)
        let reset = Task { await runtime.resetState() }
        await rig.client.waitUntilStalled(1)
        await reset.value
        // The window is still parked and its journal entry is the only way back: nothing was forgotten.
        #expect(!(await rig.plugin.journal.store.hidden.isEmpty))
        rig.client.releaseStalls()
        await rig.plugin.deactivate()
    }

    /// Lets the test hold a recovery pass until it opens the latch.
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

    @MainActor @Test func aRecoveryStuckOnAHungAppDoesNotHoldUpEraseOrTheRestoreButton() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.plugin.deactivate()
        await rig.plugin.journal.waitUntilIdle()
        // A recovery pass that never ends until released.
        let latch = Latch()
        let journal = rig.plugin.journal
        let stuck = Task { await journal.exclusive { _ in await latch.wait() } }
        var attempts = 0
        while await journal.phase != .recovering, attempts < 200_000 {
            attempts += 1
            await Task.yield()
        }
        #expect(await journal.phase == .recovering)

        // Erase Data refuses and returns instead of waiting for the pass behind the host's queue.
        await #expect(throws: WindowsPlugin.EraseRefused.self) { try await rig.plugin.eraseData() }
        // So does the button without a runtime: it says the journal is busy.
        await rig.plugin.restoreAllWindows()
        #expect(rig.hud.shown.last == .stillStopping)
        // Nothing of the two stays parked in the journal's queue.
        #expect(await journal.waiterCount == 0)

        await latch.release()
        _ = await stuck.value
        #expect(await journal.phase == .idle)
    }

    @MainActor @Test func theProductionLaunchPathCountsTheLaunchOnceAndOnlyAfterAPassThatRan() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = StateStore(directory: harness.directory)
        await store.load()
        try await store.addHidden([
            HiddenEntry(
                windowID: id(1), processStart: 1_100, homeFrame: FrameRecord(CGRect(x: 1, y: 1, width: 2, height: 2)))
        ])
        await store.close()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        // Accessibility is off: the pass runs, nothing can be put back, so the launch ended with parked windows.
        let context = harness.context(windows: client, permissions: ScriptedPermissions(granted: false))
        let settings = WindowsSettings(harness.pluginSettings)
        // An engine owns the journal: the pass does not run, so the launch is not counted.
        let lease = try #require(await JournalOwner.owner(for: context).tryBeginEngine())
        #expect(await WindowsPlugin.recoverAtLaunch(context: context) == .done)
        #expect(settings.parkedLaunches == 0)
        await JournalOwner.owner(for: context).endEngine(lease)
        // The first pass that runs is the launch's; a retry of the same launch is not another one.
        _ = await WindowsPlugin.recoverAtLaunch(context: context)
        #expect(settings.parkedLaunches == 1)
        _ = await WindowsPlugin.recoverAtLaunch(context: context)
        #expect(settings.parkedLaunches == 1)
    }

    @MainActor @Test func eraseRefusesWhileWindowsStayParkedWithoutAccessibilityAndErasesAnEmptyJournal() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = StateStore(directory: harness.directory)
        await store.load()
        try await store.addHidden([
            HiddenEntry(
                windowID: id(1), processStart: 1_100, homeFrame: FrameRecord(CGRect(x: 1, y: 1, width: 2, height: 2)))
        ])
        await store.close()
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: false)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        // Accessibility is off: nothing can put the window back, so its data is kept.
        await #expect(throws: WindowsPlugin.EraseRefused.self) { try await plugin.eraseData() }
        // Nothing parked: erasing is fine.
        let empty = try WindowsHarness()
        defer { empty.tearDown() }
        let other = WindowsPlugin(
            context: empty.context(windows: client, permissions: ScriptedPermissions(granted: false)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await other.eraseData()
    }

    @Test func afterCloseTheStoreWritesNothingUntilItIsLoadedAgain() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = StateStore(directory: harness.directory)
        await store.load()
        let entry = HiddenEntry(
            windowID: id(1), processStart: 1_100, homeFrame: FrameRecord(CGRect(x: 1, y: 1, width: 2, height: 2)))
        try await store.addHidden([entry])
        await store.close()
        await #expect(throws: StateStore.StoreError.closed) { try await store.addHidden([entry]) }
        await #expect(throws: StateStore.StoreError.closed) { try await store.removeHidden([entry.windowID]) }
        await #expect(throws: StateStore.StoreError.closed) { try await store.reset() }
        #expect(await store.hidden.count == 1)
        await store.load()
        try await store.removeHidden([entry.windowID])
        #expect(await store.hidden.isEmpty)
    }

    @Test func stopEndsTheClientsStreamBeforeItReturns() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let engine = makeEngine(client: client, store: store, clock: VirtualClock(), workspaceCount: 2)
        await engine.start()
        #expect(!client.eventsTerminated)
        await engine.stop()
        // The pump was awaited, so a restart's subscribe() cannot be handed a stream that is still dying.
        #expect(client.eventsTerminated)
    }
}
