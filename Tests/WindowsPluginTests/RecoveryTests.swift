import AppKit
import CoreGraphics
import Foundation
import LintelKit
import Synchronization
import Testing
import os

@testable import WindowsPlugin

/// Step 1.7: the journal of parked windows, `recoverAtLaunch`, restore on disable, the Accessibility gate.
@Suite(.timeLimit(.minutes(1))) struct RecoveryTests {
    private let home = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let parked = CGRect(x: 1919, y: 1079, width: 800, height: 600)

    private func id(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }

    /// A journal with these windows parked, and a fake client that shows them parked.
    private func parkedRig(
        _ numbers: [UInt32], pid: Int32 = 100, granted: Bool = true, stale: Bool = false
    ) async throws -> (WindowsHarness, FakeWindowClient, ScriptedPermissions, PluginContext) {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(
            windows: numbers.map { makeWindow($0, pid: pid, frame: parked) })
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        await store.load()
        let start = 1_000 + Double(pid) + (stale ? 500 : 0)
        try await store.addHidden(
            numbers.map {
                HiddenEntry(windowID: id($0, pid: pid), processStart: start, homeFrame: FrameRecord(home))
            })
        await store.close()
        let permissions = ScriptedPermissions(granted: granted)
        return (harness, client, permissions, harness.context(windows: client, permissions: permissions))
    }

    private func journal(_ harness: WindowsHarness) async -> [HiddenEntry] {
        let store = StateStore(directory: harness.directory)
        await store.load()
        return await store.hidden
    }

    // MARK: recoverAtLaunch

    @Test func launchRecoveryRestoresEveryParkedWindowEvenWhenThePluginIsOff() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2, 3])
        defer { harness.tearDown() }
        let shown = HUDLog()
        // The plugin is never created or activated: this is the disabled-plugin path.
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: true) { await shown.add($0) }
        #expect(outcome == .done)
        for number in [1, 2, 3] as [UInt32] { #expect(client.frame(of: id(number)) == home) }
        #expect(await journal(harness).isEmpty)
        #expect(await shown.states == [.restored(restored: 3, onAnotherSpace: 0, failed: 0)])
    }

    @Test func withoutAccessibilityNothingMovesAndTheJournalIsKept() async throws {
        let (harness, client, permissions, context) = try await parkedRig([1, 2], granted: false)
        defer { harness.tearDown() }
        let shown = HUDLog()
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: true) { await shown.add($0) }
        #expect(outcome == .deferred)
        #expect(client.calls.isEmpty)
        #expect(await journal(harness).count == 2)
        #expect(await shown.states == [.parkedNeedsAccessibility])
        // The grant arrives: the retry restores them.
        permissions.set(true)
        let retry = await WindowsPlugin.recover(context: context, isLaunch: false) { await shown.add($0) }
        #expect(retry == .done)
        #expect(client.frame(of: id(1)) == home)
        #expect(await journal(harness).isEmpty)
    }

    @Test func anEntryWhoseProcessStartDoesNotMatchIsDroppedAndNeverMoved() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2], stale: true)
        defer { harness.tearDown() }
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(outcome == .done)
        #expect(client.calls.isEmpty)
        #expect(await journal(harness).isEmpty)
    }

    @Test func aWindowOfAnAppThatDoesNotAnswerIsNotReportedAsOnAnotherSpace() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2])
        defer { harness.tearDown() }
        // Its app is hung, so the window is missing from the list like one on another Space would be.
        client.remove(id(2))
        client.setBehavior(.hung, forProcess: 100)
        let report = await WindowsPlugin.restoredReport(context: context)
        #expect(report.onAnotherSpace == 0)
        #expect(report.failed == 2)
    }

    /// Round 10 F3: the verdict comes from the read that failed, not from a second probe. The app's window list times
    /// out while a role probe would still answer, so it must not be reported as a window on another Space.
    @Test func aListThatTimesOutIsNotAnotherSpaceEvenWhenTheAppStillAnswersAProbe() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2])
        defer { harness.tearDown() }
        client.setListFails(true, forProcess: 100)
        #expect(await client.isResponding(pid: 100))
        let report = await WindowsPlugin.restoredReport(context: context)
        #expect(report.onAnotherSpace == 0)
        #expect(report.failed == 2)
    }

    @Test func aWindowOnAnotherSpaceStaysInTheJournalUntilItIsShown() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2])
        defer { harness.tearDown() }
        client.remove(id(2))
        let shown = HUDLog()
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: true) { await shown.add($0) }
        #expect(outcome == .deferred)
        #expect(client.frame(of: id(1)) == home)
        #expect(await journal(harness).map(\.windowID) == [id(2)])
        #expect(await shown.states == [.restored(restored: 1, onAnotherSpace: 1, failed: 0)])
        // The Space is shown again.
        client.add(makeWindow(2, frame: parked))
        let retry = await WindowsPlugin.recover(context: context, isLaunch: false) { _ in }
        #expect(retry == .done)
        #expect(client.frame(of: id(2)) == home)
    }

    @Test func aHungAppKeepsItsEntryAndOthersAreRestored() async throws {
        let (harness, client, _, context) = try await parkedRig([1])
        defer { harness.tearDown() }
        client.add(makeWindow(7, pid: 200, frame: parked))
        let store = StateStore(directory: harness.directory)
        await store.load()
        try await store.addHidden([
            HiddenEntry(windowID: id(7, pid: 200), processStart: 1_200, homeFrame: FrameRecord(home))
        ])
        client.setBehavior(.hung, forProcess: 200)
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(outcome == .deferred)
        #expect(client.frame(of: id(1)) == home)
        #expect(await journal(harness).map(\.windowID) == [id(7, pid: 200)])
    }

    @Test func aRunningEnginesJournalIsLeftAlone() async throws {
        let (harness, client, _, context) = try await parkedRig([1])
        defer { harness.tearDown() }
        let owner = JournalOwner.owner(for: context)
        let lease = await owner.acquireLease()
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: false) { _ in }
        #expect(outcome == .done)
        #expect(client.calls.isEmpty)
        #expect(await journal(harness).count == 1)
        // A stopping engine still owns it: the pass is deferred, not skipped as done.
        await owner.engineStopping(lease)
        #expect(await WindowsPlugin.recover(context: context, isLaunch: false) { _ in } == .deferred)
        await owner.endEngine(lease)
        #expect(await WindowsPlugin.recover(context: context, isLaunch: false) { _ in } == .done)
        #expect(client.frame(of: id(1)) == home)
    }

    @Test func twoRecoveryPassesAtOnceRunOneAfterTheOther() async throws {
        let (harness, client, _, context) = try await parkedRig([1])
        defer { harness.tearDown() }
        client.setBehavior(.stall, forProcess: 100)
        let first = Task { await WindowsPlugin.recover(context: context, isLaunch: true) { _ in } }
        await client.waitUntilStalled(1)
        let second = Task { await WindowsPlugin.recover(context: context, isLaunch: false) { _ in } }
        client.releaseStalls()
        #expect(await first.value == .done)
        #expect(await second.value == .done)
        // The second pass found the journal already cleared: the window was moved exactly once.
        #expect(client.calls.count == 1)
        #expect(await journal(harness).isEmpty)
    }

    @Test func anEngineWaitsForARunningPassAndTheJournalIsHandedBackOnlyWhenItEnds() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(
            directory: harness.directory, logger: Logger(subsystem: "com.lintelapp.tests", category: "windows"))
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let order = Mutex<[String]>([])
        let pass = Task {
            await owner.exclusive { _ in
                enter.yield()
                for await _ in gate { break }
                order.withLock { $0.append("pass ended") }
            }
        }
        for await _ in entered { break }
        #expect(await owner.phase == .recovering)
        let engine = Task { () -> UInt64 in
            let lease = await owner.acquireLease()
            order.withLock { $0.append("engine began") }
            return lease
        }
        open.yield()
        _ = await pass.value
        let lease = await engine.value
        // The engine began only after the pass had ended.
        #expect(order.withLock { $0 } == ["pass ended", "engine began"])
        #expect(await owner.phase == .engine)
        guard case .engineRunning = await owner.exclusive({ _ in 0 }) else {
            Issue.record("a running engine owns the journal")
            return
        }
        await owner.engineStopping(lease)
        guard case .engineStopping = await owner.exclusive({ _ in 0 }) else {
            Issue.record("a stopping engine still owns the journal")
            return
        }
        await owner.endEngine(lease)
        guard case .ran = await owner.exclusive({ _ in 0 }) else {
            Issue.record("the journal is free again")
            return
        }
    }

    @Test func aNewEngineWaitsForTheOldOneAndALateEndOfTheOldOneChangesNothing() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let owner = JournalOwner(
            directory: harness.directory, logger: Logger(subsystem: "com.lintelapp.tests", category: "windows"))
        let old = await owner.acquireLease()
        let order = Mutex<[String]>([])
        let next = Task { () -> UInt64 in
            let lease = await owner.acquireLease()
            order.withLock { $0.append("new engine began") }
            return lease
        }
        // The second engine cannot start while the first one still owns the journal, stopped or not.
        await owner.engineStopping(old)
        order.withLock { $0.append("old engine ended") }
        await owner.endEngine(old)
        let lease = await next.value
        #expect(order.withLock { $0 } == ["old engine ended", "new engine began"])
        #expect(lease != old)
        // The old engine reports its end a second time, late: it must not free the journal under the new one.
        await owner.endEngine(old)
        await owner.engineStopping(old)
        #expect(await owner.phase == .engine)
        await owner.endEngine(lease)
        #expect(await owner.phase == .idle)
    }

    @MainActor
    @Test func disablingAndAtOnceEnablingAgainRunsOneEngineAtATimeAndRecoveryWaitsBesideIt() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let (plugin, _) = try await activePlugin(
            harness.context(windows: client, permissions: ScriptedPermissions(granted: true)))
        let first = try #require(plugin.runtime)
        await first.engine.send(.showWorkspace(WorkspaceID(2)!))
        await plugin.deactivate()
        try await plugin.activate()
        let second = try #require(plugin.runtime)
        #expect(second !== first)
        // A recovery pass beside the new engine leaves its journal alone.
        let outcome = await WindowsPlugin.recover(context: plugin.context, isLaunch: false) { _ in }
        #expect(outcome == .done)
        #expect(await plugin.journal.phase == .engine)
        await plugin.deactivate()
        #expect(await plugin.journal.phase == .idle)
        #expect(client.frame(of: id(1)) == home)
    }

    @Test func twoLaunchesInARowWithParkedWindowsSwitchSafeModeOn() async throws {
        let (harness, _, _, context) = try await parkedRig([1], granted: false)
        defer { harness.tearDown() }
        let settings = WindowsSettings(context.settings)
        _ = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(settings.parkedLaunches == 1)
        #expect(!settings.safeMode)
        // A retry in the same launch does not count.
        _ = await WindowsPlugin.recover(context: context, isLaunch: false) { _ in }
        #expect(settings.parkedLaunches == 1)
        _ = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(settings.parkedLaunches == 2)
        #expect(settings.safeMode)
    }

    @Test func aCleanLaunchResetsTheCount() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let context = harness.context(windows: FakeWindowClient(), permissions: ScriptedPermissions(granted: true))
        let settings = WindowsSettings(context.settings)
        settings.setParkedLaunches(1)
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(outcome == .done)
        #expect(settings.parkedLaunches == 0)
    }

    // MARK: A journal from a newer version (review M1, M4)

    private func newerJournal(_ harness: WindowsHarness, processStart: Double) throws {
        let json = """
            {"version":99,"workspaces":{},"hidden":[{"windowID":{"pid":100,"number":1},"processStart":\(processStart),\
            "homeFrame":{"x":100,"y":100,"width":800,"height":600}}]}
            """
        try Data(json.utf8).write(to: harness.directory.appending(path: "state.json"))
    }

    @Test func aReadOnlyJournalRestoresOncePerProcessAndNeverCountsTowardSafeMode() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1, frame: parked)])
        let context = harness.context(windows: client, permissions: ScriptedPermissions(granted: true))
        try newerJournal(harness, processStart: 1_100)
        let first = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(first == .done)
        #expect(client.frame(of: id(1)) == home)
        _ = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        let settings = WindowsSettings(context.settings)
        #expect(settings.parkedLaunches == 0)
        #expect(!settings.safeMode)
    }

    @Test func aReadOnlyJournalStillComparesTheProcessStart() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1, frame: parked)])
        let context = harness.context(windows: client, permissions: ScriptedPermissions(granted: true))
        try newerJournal(harness, processStart: 5)
        _ = await WindowsPlugin.recover(context: context, isLaunch: true) { _ in }
        #expect(client.calls.isEmpty)
    }

    // MARK: Disable, quit, restore all

    @MainActor
    private func activePlugin(
        _ context: PluginContext, hud: RecordingHUD = RecordingHUD()
    ) async throws -> (WindowsPlugin, RecordingHUD) {
        let plugin = WindowsPlugin(context: context, hud: hud, activationCenter: NotificationCenter())
        try await plugin.activate()
        return (plugin, hud)
    }

    @MainActor
    @Test func disablingThePluginPutsEveryParkedWindowBack() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [
            makeWindow(1), makeWindow(2, frame: CGRect(x: 300, y: 200, width: 500, height: 400)),
        ])
        let (plugin, _) = try await activePlugin(
            harness.context(windows: client, permissions: ScriptedPermissions(granted: true)))
        let runtime = try #require(plugin.runtime)
        await runtime.engine.send(.showWorkspace(WorkspaceID(2)!))
        #expect(client.frame(of: id(1))?.origin == CGPoint(x: 1919, y: 1079))
        await plugin.deactivate()
        #expect(client.frame(of: id(1)) == home)
        #expect(client.frame(of: id(2)) == CGRect(x: 300, y: 200, width: 500, height: 400))
        #expect(await journal(harness).isEmpty)
        #expect(await plugin.journal.phase == .idle)
    }

    @MainActor
    @Test func restoreAllWindowsEndsWithTheHUD() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        let (plugin, hud) = try await activePlugin(
            harness.context(windows: client, permissions: ScriptedPermissions(granted: true)))
        await plugin.restoreAllWindows()
        // Nothing was parked: still answers.
        #expect(hud.shown == [.restored(restored: 0, onAnotherSpace: 0, failed: 0)])
        let runtime = try #require(plugin.runtime)
        await runtime.engine.send(.showWorkspace(WorkspaceID(2)!))
        await plugin.restoreAllWindows()
        #expect(hud.shown.last == .restored(restored: 2, onAnotherSpace: 0, failed: 0))
        #expect(client.frame(of: id(1)) == home)
        await plugin.deactivate()
    }

    @MainActor
    @Test func restoreAllWithoutAPluginInstanceWorksFromTheJournal() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2])
        defer { harness.tearDown() }
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(context: context, hud: hud, activationCenter: NotificationCenter())
        await plugin.restoreAllWindows()
        #expect(hud.shown == [.restored(restored: 2, onAnotherSpace: 0, failed: 0)])
        #expect(client.frame(of: id(1)) == home)
    }

    @MainActor
    @Test func eraseDataRestoresFirst() async throws {
        let (harness, client, _, context) = try await parkedRig([1])
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.eraseData()
        #expect(client.frame(of: id(1)) == home)
        #expect(await journal(harness).isEmpty)
    }

    @MainActor
    @Test func safeModeRefusesTheFirstStartAndTheNextOneClearsIt() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let context = harness.context(
            windows: FakeWindowClient(), permissions: ScriptedPermissions(granted: true))
        WindowsSettings(context.settings).setSafeMode(true)
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        await #expect(throws: WindowsPlugin.SafeModeFailure.self) { try await plugin.activate() }
        try await plugin.activate()
        #expect(!WindowsSettings(context.settings).safeMode)
        await plugin.deactivate()
    }

    // MARK: Nothing moves without the plugin on and Accessibility trusted

    @MainActor
    @Test func withoutAccessibilityNoCommandMovesAWindow() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        client.setFocused(id(1))
        let permissions = ScriptedPermissions(granted: false)
        let (plugin, _) = try await activePlugin(harness.context(windows: client, permissions: permissions))
        let engine = try #require(plugin.runtime).engine
        await engine.send(.showWorkspace(WorkspaceID(2)!))
        await engine.send(.moveFocusedWindow(to: WorkspaceID(3)!))
        await engine.send(.restoreAll)
        #expect(client.calls.isEmpty)
        #expect(client.focusCalls.isEmpty)
        #expect(await journal(harness).isEmpty)
        await plugin.deactivate()
        #expect(client.calls.isEmpty)
    }

    @MainActor
    @Test func aPluginThatIsNotActivatedNeverTouchesTheClient() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        #expect(plugin.runtime == nil)
        await plugin.deactivate()
        #expect(client.calls.isEmpty)
        #expect(client.windowsReads == 0)
    }

    @MainActor
    @Test func regrantingAccessibilityRestoresWhatWasParked() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let permissions = ScriptedPermissions(granted: true)
        let center = NotificationCenter()
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: permissions), hud: hud, activationCenter: center)
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        await runtime.engine.send(.showWorkspace(WorkspaceID(2)!))
        #expect(client.frame(of: id(1))?.origin == CGPoint(x: 1919, y: 1079))
        // Revoked, noticed on app activation, then granted again.
        permissions.set(false)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        #expect(!runtime.trust.isTrusted)
        permissions.set(true)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        await runtime.settle()
        #expect(client.frame(of: id(1)) == home)
        #expect(hud.shown.last == .restored(restored: 1, onAnotherSpace: 0, failed: 0))
        await plugin.deactivate()
    }

    @MainActor
    @Test func aSpaceChangeRestoresJournalEntriesThatBecameVisible() async throws {
        let (harness, client, _, context) = try await parkedRig([1, 2])
        defer { harness.tearDown() }
        client.remove(id(2))
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(context: context, hud: hud, activationCenter: NotificationCenter())
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        // The engine started with window 1 parked in the journal from an earlier run (recovery would have
        // restored it; here the plugin starts directly), window 2 is on another Space.
        client.add(makeWindow(2, frame: parked))
        await runtime.engine.submit([])
        await runtime.engine.ingest(.spaceChanged)
        await runtime.engine.flushEvents()
        #expect(client.frame(of: id(2)) == home)
        await plugin.deactivate()
    }

    @MainActor
    @Test func aSelfCheckThatFailsAfterTheGrantStopsThePlugin() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let permissions = ScriptedPermissions(granted: false)
        let center = NotificationCenter()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: permissions), hud: RecordingHUD(),
            activationCenter: center)
        try await plugin.activate()
        // With Accessibility the check can compare windows for the first time, and it disagrees.
        client.setAvailable(false)
        permissions.set(true)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        // The grant starts the re-check, which stops the plugin from inside the runtime's own task.
        await plugin.runtime?.settle()
        #expect(plugin.runtime == nil)
        #expect(plugin.lastStartError == .unsupported(reason: "scripted"))
    }

    // MARK: Pieces

    @MainActor
    @Test func trustPollingReportsAGrantOnce() async throws {
        let permissions = ScriptedPermissions(granted: false)
        let clock = VirtualClock(autoAdvance: false)
        let trust = AccessibilityTrust(reader: permissions, clock: clock, pollInterval: .milliseconds(10))
        let changes = ChangeLog()
        trust.onChange = { changes.values.append($0) }
        #expect(!trust.refresh())
        trust.startPolling { true }
        await clock.waitForSleepers(1, limit: .seconds(30))
        permissions.set(true)
        clock.advance(0.01)
        await trust.waitForPolls(1)
        #expect(trust.isTrusted)
        // Another interval later it is still trusted and nothing is reported twice.
        await clock.waitForSleepers(1, limit: .seconds(30))
        clock.advance(0.01)
        await trust.waitForPolls(2)
        trust.stop()
        #expect(changes.values == [true])
    }

    @Test func theHUDStatesReadWell() {
        let all = WindowsHUDState.restored(restored: 12, onAnotherSpace: 0, failed: 0)
        #expect(all.title == "12 windows restored")
        #expect(all.detail == nil)
        #expect(!all.needsAttention)
        let partial = WindowsHUDState.restored(restored: 9, onAnotherSpace: 3, failed: 1)
        #expect(partial.title == "9 windows restored")
        #expect(partial.detail == "On another Space: 3 · Not responding: 1")
        #expect(partial.needsAttention)
        #expect(WindowsHUDState.restored(restored: 0, onAnotherSpace: 2, failed: 0).title == "No windows restored")
        #expect(WindowsHUDState.parkedNeedsAccessibility.title == "Windows are parked")
        #expect(partial.announcement.contains("9 windows restored"))
        #expect(WindowsHUDState(report: RecoveryReport(needsAccessibility: true)) == .parkedNeedsAccessibility)
    }

    @Test func theReportsOutcomeIsDoneOnlyWhenNothingIsLeft() {
        #expect(RecoveryReport(restored: 3).outcome == .done)
        #expect(RecoveryReport(onAnotherSpace: 1).outcome == .deferred)
        #expect(RecoveryReport(failed: 1).outcome == .deferred)
        #expect(RecoveryReport(needsAccessibility: true).outcome == .deferred)
        #expect(RecoveryReport().isEmpty)
    }
}

actor HUDLog {
    private(set) var states: [WindowsHUDState] = []
    func add(_ state: WindowsHUDState) { states.append(state) }
}

@MainActor
final class ChangeLog {
    var values: [Bool] = []
}

/// Returns after everything already queued on the main queue has run: a notification posted with `queue: .main`
/// has been delivered by then. The queue is FIFO, so the marker cannot overtake it.
@MainActor
func drainMainQueue() async {
    await withCheckedContinuation { continuation in
        OperationQueue.main.addOperation { continuation.resume() }
    }
}
