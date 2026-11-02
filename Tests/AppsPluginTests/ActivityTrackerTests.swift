import Foundation
import PounceKit
import Testing

@testable import AppsPlugin

@Suite @MainActor struct ActivityTrackerTests {
    static let minute: TimeInterval = 60
    let x = "com.example.editor"
    let y = "com.example.browser"

    struct Harness {
        let time: VirtualTime
        let workspace: ScriptedWorkspace
        let store: ActivityStore
        let tracker: ActivityTracker
        let directory: TemporaryDirectory

        var uses: Int { store.snapshot.apps.values.reduce(0) { $0 + $1.useCount } }

        func uses(of bundleID: String) -> Int { store.snapshot.apps[bundleID]?.useCount ?? 0 }
    }

    func makeHarness(own: String? = "app.pounce.Pounce") async throws -> Harness {
        let time = VirtualTime()
        let directory = try TemporaryDirectory()
        let store = ActivityStore(directory: directory.url, now: time.now, clock: NeverClock())
        await store.load()
        let workspace = ScriptedWorkspace(time: time)
        let tracker = ActivityTracker(
            workspace: workspace, store: store, clock: VirtualClock(time: time), now: time.now,
            ownBundleIdentifier: own)
        return Harness(time: time, workspace: workspace, store: store, tracker: tracker, directory: directory)
    }

    /// X in front from `from` (virtual seconds) until `until`, then Y.
    func front(_ harness: Harness, _ bundleID: String, until end: TimeInterval) {
        harness.workspace.frontmost = { [y] time in time < end ? bundleID : y }
    }

    @Test func lessThanFiveSecondsDoesNotCount() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 3)
        await harness.tracker.track(x)
        #expect(harness.uses == 0)
    }

    @Test func fiveSecondsCountOnce() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 6 * Self.minute)
        await harness.tracker.track(x)
        #expect(harness.uses(of: x) == 1)
        #expect(harness.store.snapshot.apps[x]?.lastUsedAt == harness.time.origin.timeIntervalSince1970 + 5)
    }

    @Test func twentyFiveActiveMinutesGiveThreeUses() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 25 * Self.minute)
        harness.workspace.idle = { _ in 3 }
        await harness.tracker.track(x)
        #expect(harness.uses(of: x) == 3)
    }

    @Test func noInputAfterActivationGivesOnlyTheFirstUse() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 30 * Self.minute)
        harness.workspace.idle = { time in time }
        await harness.tracker.track(x)
        #expect(harness.uses(of: x) == 1)
    }

    @Test func anActivationWhileIdleGivesNoUse() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 30 * Self.minute)
        harness.workspace.idle = { time in 700 + time }
        await harness.tracker.track(x)
        #expect(harness.uses == 0)
    }

    @Test func countingResumesAtTheNextHeartbeatAfterInput() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 25 * Self.minute)
        // Input at 0 and again at 1000 s: checks at 5 s (use), 605 s (idle), 1205 s (use).
        harness.workspace.idle = { time in time < 1000 ? time : time - 1000 }
        await harness.tracker.track(x)
        #expect(harness.uses(of: x) == 2)
        #expect(harness.store.snapshot.apps[x]?.lastUsedAt == harness.time.origin.timeIntervalSince1970 + 1205)
    }

    @Test func unknownIdleTimeGivesTheFirstUseWithoutHeartbeat() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 60 * Self.minute)
        harness.workspace.idle = { _ in nil }
        await harness.tracker.track(x)
        #expect(harness.uses(of: x) == 1)
        #expect(harness.time.elapsed < Self.minute)
    }

    @Test func comingBackSoonCountsTenMinutesAfterThePreviousUse() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        // X was used at 5 s and left the front at 100 s (a new activation cancels its checks); it is back
        // at 180 s and stays until 700 s.
        harness.time.advance(to: 5)
        await harness.store.recordUse(of: x, at: harness.time.date)
        harness.time.advance(to: 180)
        harness.workspace.frontmost = { [x, y] time in time < 700 ? x : y }
        await harness.tracker.track(x)
        #expect(harness.uses(of: x) == 2)
        #expect(harness.store.snapshot.apps[x]?.lastUsedAt == harness.time.origin.timeIntervalSince1970 + 605)
    }

    @Test func pounceAndAppsWithoutBundleIdentifierAreIgnored() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        harness.workspace.frontmost = { _ in "app.pounce.Pounce" }
        harness.tracker.activated(RunningApplication(processIdentifier: 2, bundleIdentifier: "app.pounce.Pounce"))
        await harness.tracker.waitForChecks()
        harness.tracker.activated(RunningApplication(processIdentifier: 3, bundleIdentifier: nil))
        await harness.tracker.waitForChecks()
        #expect(harness.uses == 0)
    }

    @Test func activationsFromThePortAreTracked() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        front(harness, x, until: 6 * Self.minute)
        harness.tracker.start()
        harness.workspace.activationsContinuation.yield(RunningApplication(processIdentifier: 4, bundleIdentifier: x))
        #expect(await eventually { @MainActor in harness.uses(of: x) == 1 })
        harness.tracker.stop()
        #expect(!harness.tracker.isRunning)
    }

    @Test func stopCancelsPendingChecks() async throws {
        let time = VirtualTime()
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = ActivityStore(directory: directory.url, now: time.now, clock: NeverClock())
        await store.load()
        let workspace = ScriptedWorkspace(time: time)
        workspace.frontmost = { [x] _ in x }
        let tracker = ActivityTracker(
            workspace: workspace, store: store, clock: NeverClock(), now: time.now, ownBundleIdentifier: nil)
        tracker.activated(RunningApplication(processIdentifier: 5, bundleIdentifier: x))
        tracker.stop()
        tracker.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.snapshot.apps.isEmpty)
    }
}
