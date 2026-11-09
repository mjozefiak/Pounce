import AppKit
import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Step 1.7: the journal of parked windows, `recoverAtLaunch`, restore on disable, the Accessibility gate.
@Suite struct RecoveryTests {
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
        ActiveEngines.insert(harness.directory)
        defer { ActiveEngines.remove(harness.directory) }
        let outcome = await WindowsPlugin.recover(context: context, isLaunch: false) { _ in }
        #expect(outcome == .done)
        #expect(client.calls.isEmpty)
        #expect(await journal(harness).count == 1)
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
        #expect(!ActiveEngines.contains(harness.directory))
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
        await #expect(throws: WindowsPlugin.StartError.safeMode) { try await plugin.activate() }
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
        try await waitUntil { !runtime.trust.isTrusted }
        permissions.set(true)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await waitUntil { client.frame(of: id(1)) == home }
        try await waitUntil { hud.shown.last == .restored(restored: 1, onAnotherSpace: 0, failed: 0) }
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
        try await waitUntil { client.frame(of: id(2)) == home }
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
        try await waitUntil { plugin.runtime == nil }
        #expect(plugin.lastStartError == .unsupported(reason: "scripted"))
    }

    // MARK: Pieces

    @MainActor
    @Test func trustPollingReportsAGrantOnce() async throws {
        let permissions = ScriptedPermissions(granted: false)
        let trust = AccessibilityTrust(reader: permissions, clock: ContinuousClock(), pollInterval: .milliseconds(10))
        let changes = ChangeLog()
        trust.onChange = { changes.values.append($0) }
        #expect(!trust.refresh())
        trust.startPolling { true }
        permissions.set(true)
        try await waitUntil { trust.isTrusted }
        try await Task.sleep(for: .milliseconds(50))
        trust.stop()
        #expect(changes.values == [true])
    }

    @Test func aTimeBoundGivesUpOnWorkThatDoesNotFinish() async {
        let quick = await TimeBound.run(budget: .seconds(1), clock: ContinuousClock()) {}
        #expect(quick)
        let slow = await TimeBound.run(budget: .milliseconds(30), clock: ContinuousClock()) {
            await Task.detached { usleep(400_000) }.value
        }
        #expect(!slow)
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

/// Polls a condition for up to 3 seconds.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<300 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met in time")
}
