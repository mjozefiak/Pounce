import CoreGraphics
import Foundation
import LintelKit
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

        var outputs: EngineOutputs {
            EngineOutputs(
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
        tick: Duration = .milliseconds(5)
    ) throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(displays: displays, windows: windows)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let recorder = Recorder()
        let time = ManualNow()
        let engine = WindowEngine(
            client: client, store: store, now: { time.now }, workspaceCount: count, config: config,
            tick: tick, watchdog: watchdog, outputs: recorder.outputs)
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
        #expect((await rig.engine.state).canJournal == false)
        #expect((await rig.engine.state).diagnostics.refusedParks == 1)
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
        #expect((await rig.engine.state).model.current == ws(1))
        await rig.engine.stop()
    }

    @Test func anAppThatMovesItsHiddenWindowBackIsHiddenAgainAtMostThreeTimes() async throws {
        let rig = try rig([makeWindow(1)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.setBehavior(.snapBack(CGRect(x: 400, y: 300, width: 800, height: 600)), for: id(1))
        await rig.engine.send(.showWorkspace(ws(2)))
        // The fake emits a move after each of our changes; the pump delivers them.
        for _ in 0..<40 {
            await rig.engine.settle()
            try await Task.sleep(for: .milliseconds(10))
        }
        await rig.engine.settle()
        let state = await rig.engine.state
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
        rig.client.setEchoes(true)
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        for _ in 0..<10 {
            await rig.engine.settle()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rig.client.calls.count == 2)
        let state = await rig.engine.state
        #expect(state.diagnostics.echoesDropped >= 1)
        #expect(state.diagnostics.rehides == 0)
        await rig.engine.stop()
    }

    @Test func anEventStormIsReadOnceAndCostsNoFrameChanges() async throws {
        // A tick that never fires on its own: the test flushes by hand, so the count of reads is exact.
        let rig = try rig([makeWindow(1), makeWindow(2, pid: 200)], tick: .seconds(3600))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        let readsBefore = rig.client.windowsReads
        for index in 0..<2_000 {
            await rig.engine.ingest(index.isMultiple(of: 2) ? .moved(id(1)) : .resized(id(1)))
        }
        await rig.engine.flushEvents()
        #expect(rig.client.windowsReads == readsBefore + 1)
        #expect(rig.client.calls.isEmpty)
        #expect(await rig.engine.frameChangeCount == 0)
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
        #expect((await rig.engine.state).windows.isEmpty)
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
        #expect((await rig.engine.state).model.workspace(of: id(5, pid: 300)) == ws(2))
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
        let state = await rig.engine.state
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
        await rig.engine.submit([.place(id(1), tile, now: rig.time.now)])
        let state = await rig.engine.state
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
        let state = await rig.engine.state
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
        #expect((await rig.engine.state).model.workspace(of: id(2, pid: 200)) == ws(2))

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
        #expect((await rig.engine.state).windows.keys.sorted() == [id(2, pid: 200)])
    }

    // MARK: Parallelism and privacy

    @Test func framesOfDifferentAppsAreSetInParallelAndOfOneAppInOrder() async throws {
        var windows = (1...4).map { makeWindow(UInt32($0), pid: 100 + Int32($0)) }
        windows.append(makeWindow(10, pid: 101))
        let rig = try rig(windows)
        defer { rig.harness.tearDown() }
        rig.client.setLatency(.milliseconds(40))
        await rig.engine.start()
        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.maxInFlight >= 2)
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
            WindowEngine.coalesce(effects) == [
                .journalPark([entry]), .setFrame(newer), .journalRemove([id(1)]),
                .hud(workspace: ws(2), windowCount: 0),
            ])
        // An older request that arrives after a newer one is dropped too.
        #expect(WindowEngine.coalesce([.setFrame(newer), .setFrame(older)]) == [.setFrame(newer)])
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
        let engine = WindowEngine(client: client, store: store, tick: .milliseconds(5))
        await engine.start()
        // A window the engine never heard of moves: it is tracked from then on.
        client.add(makeWindow(2))
        await engine.ingest(.moved(WindowID(pid: 100, number: 2)))
        await engine.settle()
        #expect(await engine.state.windows.keys.contains(WindowID(pid: 100, number: 2)))
        // It goes fullscreen (reported as a resize): it is let go.
        client.remove(WindowID(pid: 100, number: 2))
        client.add(makeWindow(2, fullscreen: true))
        await engine.ingest(.resized(WindowID(pid: 100, number: 2)))
        await engine.settle()
        #expect(await engine.state.windows[WindowID(pid: 100, number: 2)] == nil)
        // And it is managed again when it leaves fullscreen.
        client.remove(WindowID(pid: 100, number: 2))
        client.add(makeWindow(2))
        await engine.ingest(.resized(WindowID(pid: 100, number: 2)))
        await engine.settle()
        #expect(await engine.state.windows[WindowID(pid: 100, number: 2)] != nil)
        await engine.stop()
    }
}
