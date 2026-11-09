import CoreGraphics
import Foundation
import LintelKit
import Synchronization
import Testing

@testable import WindowsPlugin

/// The engine against a scriptable fake client and a real `StateStore` in a temporary directory. These run under
/// Thread Sanitizer in CI (`--filter WindowEngineTests`).
@Suite struct WindowEngineTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }
    private let home = CGRect(x: 100, y: 100, width: 800, height: 600)

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _banners: [EngineBanner] = []
        private var _huds: [Int] = []
        private var _summaries: [WorkspaceSummary] = []

        var banners: [EngineBanner] { lock.withLock { _banners } }
        var huds: [Int] { lock.withLock { _huds } }
        var summaries: [WorkspaceSummary] { lock.withLock { _summaries } }

        var reporter: EngineReporter {
            EngineReporter(
                hud: { workspace, _ in self.lock.withLock { self._huds.append(workspace.rawValue) } },
                summary: { summary in self.lock.withLock { self._summaries.append(summary) } },
                banner: { banner in self.lock.withLock { self._banners.append(banner) } })
        }
    }

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let store: StateStore
        let engine: WindowEngine
        let recorder: Recorder
        let time: ManualNow
    }

    private func rig(
        _ windows: [WindowInfo], displays: [DisplayInfo] = [FakeWindowClient.mainDisplay], count: Int = 4,
        watchdog: Watchdog = Watchdog(), config: EngineConfig = EngineConfig(),
        tick: Duration = .milliseconds(5), autoTick: Bool = true
    ) throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(displays: displays, windows: windows)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let recorder = Recorder()
        let time = ManualNow(autoAdvance: autoTick)
        let engine = makeEngine(
            client: client, store: store, clock: time, workspaceCount: count, config: config,
            tick: tick, watchdog: watchdog, reporter: recorder.reporter)
        return Rig(harness: harness, client: client, store: store, engine: engine, recorder: recorder, time: time)
    }

    private var parkedOrigin: CGPoint { CGPoint(x: 1919, y: 1079) }

    // MARK: Hide and restore

    @Test func switchingParksTheOldWindowsAndComingBackRestoresThem() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2, pid: 200)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()

        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.frame(of: id(1))?.origin == parkedOrigin)
        #expect(rig.client.frame(of: id(2, pid: 200))?.origin == parkedOrigin)
        #expect(await rig.store.hidden.count == 2)
        #expect(rig.recorder.huds == [2])

        await rig.engine.send(.backAndForth)
        #expect(rig.client.frame(of: id(1)) == home)
        #expect(rig.client.frame(of: id(2, pid: 200)) == home)
        #expect(await rig.store.hidden.isEmpty)
        await rig.engine.stop()
    }

    @Test func theJournalIsOnDiskBeforeTheFirstWindowMoves() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        // An unwritable folder: the journal cannot be written, so nothing may be parked.
        await rig.engine.start()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.harness.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.harness.directory.path)
        }

        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.calls.isEmpty)
        #expect(rig.client.frame(of: id(1)) == home)
        #expect(rig.recorder.banners.contains(.cannotJournal))
        #expect((await rig.engine.snapshot).canJournal == false)
        #expect((await rig.engine.snapshot).diagnostics.refusedParks == 1)
    }

    @Test func aKillAfterTheJournalWriteLeavesTheEntryForTheNextLaunch() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        // No stop(): the process "dies" here. A new store reads what is on disk.
        let reread = StateStore(directory: rig.harness.directory)
        await reread.load()
        let hidden = await reread.hidden
        #expect(hidden.map(\.windowID) == [id(1)])
        #expect(hidden[0].homeFrame == FrameRecord(home))
        #expect(hidden[0].processStart == 1_100)
    }

    @Test func stoppingRestoresEveryParkedWindow() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2, pid: 200)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(3)))
        await rig.engine.stop()
        #expect(rig.client.frame(of: id(1)) == home)
        #expect(rig.client.frame(of: id(2, pid: 200)) == home)
        let reread = StateStore(directory: rig.harness.directory)
        await reread.load()
        #expect(await reread.hidden.isEmpty)
    }

    @Test func membershipIsSavedAfterAChange() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.stop()
        let reread = StateStore(directory: rig.harness.directory)
        await reread.load()
        #expect(await reread.state.order == [ws(1): [id(1)]])
    }

    // MARK: Follow focus, re-hide

    @Test func focusingAHiddenWindowSwitchesToItsWorkspace() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.frame(of: id(1))?.origin == parkedOrigin)

        rig.client.setFocused(id(1))
        await rig.engine.ingest(.focused(id(1)))
        await rig.engine.settle()
        #expect(rig.client.frame(of: id(1)) == home)
        #expect((await rig.engine.snapshot).model.current == ws(1))
        await rig.engine.stop()
    }

    @Test func anAppThatMovesItsHiddenWindowBackIsHiddenAgainAtMostThreeTimes() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.setDeliversEvents(false)
        rig.client.setBehavior(.snapBack(CGRect(x: 400, y: 300, width: 800, height: 600)), for: id(1))
        await rig.engine.send(.showWorkspace(ws(2)))
        // The app moves the window back after each of our changes; the engine hears of it, one event at a time.
        for _ in 0..<4 {
            await rig.engine.ingest(.moved(id(1)))
            await rig.engine.flushEvents()
        }
        let state = await rig.engine.snapshot
        #expect(state.unmanaged == [id(1)])
        #expect(state.diagnostics.rehides == 4)
        // One park, three re-hides: bounded, never a loop.
        #expect(rig.client.calls.count == 4)
        #expect(await rig.store.hidden.isEmpty)
    }

    // MARK: Echoes and storms

    @Test func ourOwnEchoesDoNotMakeTheEngineLoop() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2, pid: 200)])
        defer { rig.harness.tearDown() }
        rig.client.setDeliversEvents(false)
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        // Each frame we set comes back as a move of that window: exactly our own echoes.
        await rig.engine.ingest(.moved(id(1)))
        await rig.engine.ingest(.moved(id(2, pid: 200)))
        await rig.engine.flushEvents()
        #expect(rig.client.calls.count == 2)
        let state = await rig.engine.snapshot
        #expect(state.diagnostics.echoesDropped >= 1)
        #expect(state.diagnostics.rehides == 0)
        await rig.engine.stop()
    }

    @Test func anEventStormIsReadOnceAndCostsNoFrameChanges() async throws {
        // A tick that never fires on its own: the test flushes by hand, so the count of reads is exact.
        let rig = try rig([makeWindow(1), makeWindow(2, pid: 200)], tick: .seconds(3600), autoTick: false)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        let readsBefore = rig.client.windowsReads
        for index in 0..<2_000 {
            await rig.engine.ingest(index.isMultiple(of: 2) ? .moved(id(1)) : .resized(id(1)))
        }
        await rig.engine.flushEvents()
        // One single-window read, and no full scan of every app.
        #expect(rig.client.windowsReads == readsBefore)
        #expect(rig.client.singleReads == 1)
        #expect(rig.client.calls.isEmpty)
        await rig.engine.stop()
    }

    @Test func eventsForAWindowThatIsAlreadyGoneAreHarmless() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        rig.client.remove(id(1))
        // Re-ordered: a move after the close, then the close.
        await rig.engine.ingest(.moved(id(1)))
        await rig.engine.ingest(.destroyed(id(1)))
        await rig.engine.flushEvents()
        await rig.engine.settle()
        #expect((await rig.engine.snapshot).windows.isEmpty)
        #expect(await rig.store.hidden.isEmpty)
        #expect(rig.client.calls.count == 1)
    }

    @Test func aNewWindowJoinsTheShownWorkspace() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        rig.client.add(makeWindow(5, pid: 300))
        await rig.engine.ingest(.created(id(5, pid: 300)))
        await rig.engine.flushEvents()
        #expect((await rig.engine.snapshot).model.workspace(of: id(5, pid: 300)) == ws(2))
        #expect(rig.client.frame(of: id(5, pid: 300)) == home)
    }

    // MARK: Failures

    @Test func aHungAppDoesNotBlockTheOthersAndIsNotRetriedInALoop() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2, pid: 200)])
        defer { rig.harness.tearDown() }
        rig.client.setBehavior(.hung, forProcess: 100)
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.frame(of: id(2, pid: 200))?.origin == parkedOrigin)
        #expect(rig.client.frame(of: id(1)) == home)
        let state = await rig.engine.snapshot
        #expect(state.diagnostics.accessibilityTimeouts == 1)
        #expect(rig.client.calls.filter { $0.id == id(1) }.count == 1)
        // The window that was not parked is not in the journal.
        #expect(await rig.store.hidden.map(\.windowID) == [id(2, pid: 200)])
    }

    @Test func aWindowThatRefusesItsSizeIsCentredOnceAndThenLeftAlone() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        rig.client.setMinimumSize(CGSize(width: 900, height: 700), for: id(1))
        await rig.engine.start()
        let tile = CGRect(x: 0, y: 25, width: 400, height: 300)
        await rig.engine.submit([.place(id(1), tile, now: rig.time.seconds)])
        let state = await rig.engine.snapshot
        #expect(state.stubborn == [id(1)])
        #expect(rig.client.calls.count == 2)
        #expect(rig.client.frame(of: id(1))?.size == CGSize(width: 900, height: 700))
        await rig.engine.submit([])
        #expect(rig.client.calls.count == 2)
    }

    // MARK: Watchdog, displays

    @Test func theWatchdogFreezesTheEngineAndRestoresEveryWindow() async throws {
        let windows = (1...6).map { makeWindow(UInt32($0), pid: 100 + Int32($0)) }
        let rig = try rig(windows, watchdog: Watchdog(limit: 2, sustain: 0))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        let state = await rig.engine.snapshot
        #expect(state.isFrozen)
        #expect(state.diagnostics.watchdogTrips == 1)
        #expect(rig.recorder.banners.contains(.watchdogTripped))
        // Nothing stays parked.
        #expect(await rig.store.hidden.isEmpty)
        for window in windows {
            #expect(rig.client.frame(of: window.id)?.origin != parkedOrigin)
        }
    }

    @Test func aRemovedDisplayParksItsWorkspaceAndAnAddedOneRestoresIt() async throws {
        let onSecond = makeWindow(2, pid: 200, frame: CGRect(x: 2_000, y: 100, width: 800, height: 600))
        let rig = try rig(
            [makeWindow(1), onSecond], displays: [FakeWindowClient.mainDisplay, FakeWindowClient.secondDisplay])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect((await rig.engine.snapshot).model.workspace(of: id(2, pid: 200)) == ws(2))

        rig.client.setDisplays([FakeWindowClient.mainDisplay])
        await rig.engine.ingest(.displaysChanged)
        await rig.engine.flushEvents()
        #expect(rig.client.frame(of: id(2, pid: 200))?.origin == parkedOrigin)

        rig.client.setDisplays([FakeWindowClient.mainDisplay, FakeWindowClient.secondDisplay])
        await rig.engine.ingest(.displaysChanged)
        await rig.engine.flushEvents()
        #expect(rig.client.frame(of: id(2, pid: 200))?.origin.x ?? 0 >= 1_920)
        #expect(await rig.store.hidden.isEmpty)
        await rig.engine.stop()
    }

    @Test func aSpaceChangeLooksAtEverythingAgain() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.add(makeWindow(2, pid: 200))
        rig.client.remove(id(1))
        await rig.engine.ingest(.spaceChanged)
        await rig.engine.flushEvents()
        #expect((await rig.engine.snapshot).windows.keys.sorted() == [id(2, pid: 200)])
    }

    // MARK: Parallelism and privacy

    @Test func framesOfDifferentAppsAreSetInParallelAndOfOneAppInOrder() async throws {
        var windows = (1...4).map { makeWindow(UInt32($0), pid: 100 + Int32($0)) }
        windows.append(makeWindow(10, pid: 101))
        let rig = try rig(windows)
        defer { rig.harness.tearDown() }
        // Two apps whose first call waits for the other: that only ends when they run at the same time.
        rig.client.setBehavior(.stall, forProcess: 101)
        rig.client.setBehavior(.stall, forProcess: 102)
        await rig.engine.start()
        let hide = Task { await rig.engine.send(.showWorkspace(ws(2))) }
        await rig.client.waitUntilStalled(2)
        rig.client.releaseStalls()
        await hide.value
        let sameApp = rig.client.calls.filter { $0.id.pid == 101 }.map(\.id.number)
        #expect(sameApp == [1, 10])
        await rig.engine.stop()
    }

    @Test func theJournalFileHoldsNoTitleAndNoBundleID() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        let text = try String(contentsOf: rig.store.fileURL, encoding: .utf8)
        #expect(!text.contains("secret title"))
        #expect(!text.contains("com.example.app"))
        await rig.engine.stop()
    }

    @Test func coalescingKeepsTheNewestFrameChangePerWindowAndOrdersTheJournalFirst() {
        let entry = HiddenEntry(windowID: id(1), processStart: 1, homeFrame: FrameRecord(home))
        let older = FrameRequest(id: id(1), frame: .zero, generation: 1, purpose: .park)
        let newer = FrameRequest(id: id(1), frame: home, generation: 2, purpose: .restore)
        let effects: [EngineEffect] = [
            .hud(workspace: ws(2), windowCount: 0), .setFrame(older), .journalPark([entry]), .setFrame(newer),
            .journalRemove([id(1)]),
        ]
        #expect(
            EffectExecutor.coalesce(effects) == [
                .journalPark([entry]), .setFrame(newer), .journalRemove([id(1)]),
                .hud(workspace: ws(2), windowCount: 0),
            ])
        // An older request that arrives after a newer one is dropped too.
        #expect(EffectExecutor.coalesce([.setFrame(newer), .setFrame(older)]) == [.setFrame(newer)])
    }
}

extension WindowEngineTests {
    /// Step 1.8b: a move of a window the engine does not hold yet, or that came back from fullscreen, is looked
    /// at as an appearance.
    @Test func aMoveOfAnUnknownOrUnmanagedWindowIsLookedAtAsAnAppearance() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let engine = makeEngine(client: client, store: store, tick: .milliseconds(5))
        await engine.start()
        // A window the engine never heard of moves: it is tracked from then on.
        client.add(makeWindow(2))
        await engine.ingest(.moved(WindowID(pid: 100, number: 2)))
        await engine.settle()
        #expect(await engine.snapshot.windows.keys.contains(WindowID(pid: 100, number: 2)))
        // It goes fullscreen (reported as a resize): it is let go.
        client.remove(WindowID(pid: 100, number: 2))
        client.add(makeWindow(2, fullscreen: true))
        await engine.ingest(.resized(WindowID(pid: 100, number: 2)))
        await engine.settle()
        #expect(await engine.snapshot.windows[WindowID(pid: 100, number: 2)] == nil)
        // And it is managed again when it leaves fullscreen.
        client.remove(WindowID(pid: 100, number: 2))
        client.add(makeWindow(2))
        await engine.ingest(.resized(WindowID(pid: 100, number: 2)))
        await engine.settle()
        #expect(await engine.snapshot.windows[WindowID(pid: 100, number: 2)] != nil)
        await engine.stop()
    }
}

/// The engine keeps reducing while an app does not answer, and a call returns only when its work has run.
@Suite struct WindowEngineConcurrencyTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32, pid: Int32) -> WindowID { WindowID(pid: pid, number: number) }
    private var parkedOrigin: CGPoint { CGPoint(x: 1919, y: 1079) }

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let store: StateStore
        let engine: WindowEngine
    }

    private func rig(_ windows: [WindowInfo]) throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: windows)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let engine = makeEngine(
            client: client, store: store, clock: VirtualClock(), workspaceCount: 4, tick: .milliseconds(5))
        return Rig(harness: harness, client: client, store: store, engine: engine)
    }

    @Test func aHungAppDelaysOnlyItself() async throws {
        let hung = makeWindow(1, pid: 100)
        let other = makeWindow(2, pid: 200)
        let rig = try rig([hung, other])
        defer { rig.harness.tearDown() }
        rig.client.setBehavior(.stall, forProcess: 100)
        await rig.engine.start()
        // Workspace 2 is empty, so showing it parks both windows; the first app never answers.
        let hide = Task { await rig.engine.send(.showWorkspace(ws(2))) }
        await rig.client.waitUntilStalled(1)
        await rig.client.waitUntilCompleted(1)
        // The other app is already parked and the journal holds both, while the first call is still waiting.
        #expect(rig.client.frame(of: other.id)?.origin == parkedOrigin)
        // The reducer is not blocked: a second switch is reduced and executed for the other app at once.
        let show = Task { await rig.engine.send(.showWorkspace(ws(1))) }
        await rig.client.waitUntilCalls(3)
        #expect(rig.client.frame(of: other.id)?.origin != parkedOrigin)
        // The hung app's park result arrives late and is stale (its restore is newer): the window ends restored.
        rig.client.releaseStalls()
        await hide.value
        await show.value
        await rig.engine.settle()
        let state = await rig.engine.snapshot
        #expect(state.parked.isEmpty)
        #expect(rig.client.frame(of: hung.id)?.origin != parkedOrigin)
        #expect(await rig.store.hidden.isEmpty)
        await rig.engine.stop()
    }

    @Test func restoreAllWindowsReportsAfterTheBatchRan() async throws {
        let rig = try rig([makeWindow(1, pid: 100), makeWindow(2, pid: 200)])
        defer { rig.harness.tearDown() }
        rig.client.setBehavior(.stall, forProcess: 100)
        await rig.engine.start()
        let hide = Task { await rig.engine.send(.showWorkspace(ws(2))) }
        await rig.client.waitUntilStalled(1)
        let order = Mutex<[String]>([])
        let restore = Task {
            let report = await rig.engine.restoreAllWindows()
            order.withLock { $0.append("reported") }
            return report
        }
        // The report may only come after the app that did not answer was let go.
        order.withLock { $0.append("released") }
        rig.client.releaseStalls()
        let report = await restore.value
        #expect(order.withLock { $0 } == ["released", "reported"])
        await hide.value
        #expect(report.restored == 2)
        #expect(report.failed == 0)
        #expect(await rig.store.hidden.isEmpty)
        await rig.engine.stop()
    }

    @Test func stopDuringARunningBatchWaitsForItAndLeavesNothingParked() async throws {
        let hung = makeWindow(1, pid: 100)
        let rig = try rig([hung, makeWindow(2, pid: 200)])
        defer { rig.harness.tearDown() }
        rig.client.setBehavior(.stall, forProcess: 100)
        await rig.engine.start()
        let hide = Task { await rig.engine.send(.showWorkspace(ws(2))) }
        await rig.client.waitUntilStalled(1)
        let stopped = Task { await rig.engine.stop() }
        rig.client.releaseStalls()
        await stopped.value
        await hide.value
        #expect(rig.client.frame(of: hung.id)?.origin != parkedOrigin)
        #expect(rig.client.frame(of: id(2, pid: 200))?.origin != parkedOrigin)
        #expect(await rig.store.hidden.isEmpty)
    }
}
