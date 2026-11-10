import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Auto-tile in the engine (step 2.4) against the fake client: new and closed windows, the kind per workspace,
/// floating, stubborn windows, the Accessibility gate and persistence. Runs under TSan in CI (`Tiling`).
@Suite(.timeLimit(.minutes(1))) struct TilingEngineTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }

    /// The display of `FakeWindowClient.mainDisplay`: visible frame (0, 25, 1920, 1055).
    private let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let store: StateStore
        let engine: WindowEngine
        let time: ManualNow
    }

    private func tilingConfig(
        kind: LayoutKind = .tiling, overrides: [WorkspaceID: WorkspaceOverride] = [:], inner: Int = 0, outer: Int = 0
    ) -> EngineConfig {
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: kind, innerGap: inner, outerGap: outer, rootOrientation: .horizontal, overrides: overrides)
        return config
    }

    private func rig(
        _ windows: [WindowInfo], config: EngineConfig? = nil, focused: WindowID? = nil,
        canMove: @escaping @Sendable () -> Bool = { true }, directory: WindowsHarness? = nil, count: Int = 4
    ) throws -> Rig {
        let harness = try directory ?? WindowsHarness()
        let client = FakeWindowClient(windows: windows)
        client.setFocused(focused)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let time = ManualNow()
        let engine = makeEngine(
            client: client, store: store, clock: time, workspaceCount: count,
            config: config ?? tilingConfig(), tick: .milliseconds(5), canMove: canMove)
        return Rig(harness: harness, client: client, store: store, engine: engine, time: time)
    }

    // MARK: Arranging

    @Test func theWindowsOfAnAutoTileWorkspaceFillTheScreen() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(rig.client.frame(of: id(2)) == CGRect(x: 960, y: 25, width: 960, height: 1055))
        await rig.engine.stop()
    }

    @Test func gapsAreHonoured() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], config: tilingConfig(inner: 10, outer: 20))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 20, y: 45, width: 935, height: 1015))
        #expect(rig.client.frame(of: id(2)) == CGRect(x: 965, y: 45, width: 935, height: 1015))
        await rig.engine.stop()
    }

    @Test func aNewWindowIsInsertedAfterTheFocusedOne() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.add(makeWindow(3))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        // Layout order: 1, 3, 2.
        let third: CGFloat = 1920.0 / 3
        #expect(rig.client.frame(of: id(1))?.minX == 0)
        #expect(rig.client.frame(of: id(3))?.minX == third.rounded())
        #expect(rig.client.frame(of: id(2))?.minX == (2 * third).rounded())
        #expect((await rig.engine.snapshot).tiling[ws(1)]?.windows == [id(1), id(3), id(2)])
        await rig.engine.stop()
    }

    @Test func aNewWindowThatTookTheFocusStillGoesAfterTheOneFocusedBefore() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2), makeWindow(3)], focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.add(makeWindow(4))
        // The new window appears, then takes the focus; a later window is added after the first one.
        await rig.engine.ingest(.created(id(4)))
        await rig.engine.settle()
        rig.client.setFocused(id(4))
        await rig.engine.ingest(.focused(id(4)))
        await rig.engine.settle()
        #expect((await rig.engine.snapshot).tiling[ws(1)]?.windows == [id(1), id(4), id(2), id(3)])
        #expect((await rig.engine.snapshot).previousFocus == id(1))
        await rig.engine.stop()
    }

    @Test func aClosedWindowGivesItsSpaceToTheOthers() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2), makeWindow(3)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.remove(id(2))
        await rig.engine.ingest(.destroyed(id(2)))
        await rig.engine.settle()
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(rig.client.frame(of: id(3)) == CGRect(x: 960, y: 25, width: 960, height: 1055))
        await rig.engine.stop()
    }

    @Test func aWorkspaceThatIsNotShownIsNotArrangedUntilItIs() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveFocusedWindow(to: ws(2)))
        rig.client.clearCalls()
        await rig.engine.send(.showWorkspace(ws(2)))
        // Workspace 2 holds no window yet (nothing was focused); put window 2 there and look.
        await rig.engine.send(.showWorkspace(ws(1)))
        rig.client.setFocused(id(2))
        await rig.engine.ingest(.focused(id(2)))
        await rig.engine.settle()
        await rig.engine.send(.moveFocusedWindow(to: ws(2)))
        // Window 1 now fills workspace 1; window 2 is parked on workspace 2.
        #expect(rig.client.frame(of: id(1)) == area)
        #expect(rig.client.frame(of: id(2))?.origin == CGPoint(x: 1919, y: 1079))
        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.frame(of: id(2)) == area)
        #expect(rig.client.frame(of: id(1))?.origin == CGPoint(x: 1919, y: 1079))
        await rig.engine.stop()
    }

    // MARK: Kinds

    @Test func aFreeWorkspaceIsNeverArranged() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], config: tilingConfig(kind: .free))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.calls.isEmpty)
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        await rig.engine.stop()
    }

    @Test func aZonesWorkspaceHasNoTilingTree() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], config: tilingConfig(kind: .zones))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        // Zones place the windows (`ZoneEngineTests`); no tiling tree is ever built for the workspace.
        #expect((await rig.engine.snapshot).tiling.isEmpty)
        await rig.engine.stop()
    }

    @Test func aWorkspaceOverrideBeatsTheDefaultKind() async throws {
        let config = tilingConfig(kind: .tiling, overrides: [ws(1): WorkspaceOverride(kind: .free)])
        let rig = try rig([makeWindow(1), makeWindow(2)], config: config)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.calls.isEmpty)
        await rig.engine.stop()
    }

    @Test func changingTheKindToFreeKeepsTheTreeAndLeavesWindowsWhereTheyAre() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        let tree = (await rig.engine.snapshot).tiling[ws(1)]
        rig.client.clearCalls()
        await rig.engine.update(config: tilingConfig(kind: .free))
        #expect(rig.client.calls.isEmpty)
        #expect((await rig.engine.snapshot).tiling[ws(1)] == tree)
        // Back to Auto-tile: tiled again, from the kept state.
        rig.time.advance(2)
        rig.client.moveBehindTheEnginesBack(id(1), to: CGRect(x: 5, y: 5, width: 300, height: 300))
        await rig.engine.ingest(.moved(id(1)))
        await rig.engine.settle()
        await rig.engine.update(config: tilingConfig(kind: .tiling))
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        await rig.engine.stop()
    }

    @Test func aRootOrientationOverrideStacksTheWindows() async throws {
        let config = tilingConfig(overrides: [ws(1): WorkspaceOverride(rootOrientation: .vertical)])
        let rig = try rig([makeWindow(1), makeWindow(2)], config: config)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 1920, height: 528))
        await rig.engine.stop()
    }

    // MARK: Floating

    @Test func toggleFloatingTakesTheFocusedWindowOutOfTheTreeAndBack() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.toggleFloating)
        #expect((await rig.engine.snapshot).floating == [id(1)])
        #expect(rig.client.frame(of: id(2)) == area)
        // The floating window stays where it was.
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        await rig.engine.send(.toggleFloating)
        #expect((await rig.engine.snapshot).floating.isEmpty)
        // It comes back at the end (nothing else was focused before it), so window 2 moves to the left.
        #expect(rig.client.frame(of: id(2)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 960, y: 25, width: 960, height: 1055))
        await rig.engine.stop()
    }

    @Test func windowsOfFloatingAppsAreNeverTiled() async throws {
        var config = tilingConfig()
        config.floatingBundleIDs = ["com.apple.calculator"]
        let rig = try rig(
            [makeWindow(1), makeWindow(2, bundleID: "com.apple.calculator")], config: config)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == area)
        #expect(rig.client.frame(of: id(2)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        await rig.engine.stop()
    }

    @Test func anAppAddedToTheFloatingListLeavesTheTree() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2, bundleID: "com.example.other")])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        var config = tilingConfig()
        config.floatingBundleIDs = ["com.example.other"]
        await rig.engine.update(config: config)
        #expect((await rig.engine.snapshot).tiling[ws(1)]?.windows == [id(1)])
        #expect(rig.client.frame(of: id(1)) == area)
        await rig.engine.stop()
    }

    @Test func dialogsAndFullscreenWindowsAreNotTiled() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2, standard: false), makeWindow(3, fullscreen: true)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == area)
        #expect(rig.client.calls.count == 1)
        await rig.engine.stop()
    }

    // MARK: Stubborn windows

    @Test func aWindowThatRefusesTheTileSizeIsCentredInItOnce() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        rig.client.setMinimumSize(CGSize(width: 1200, height: 400), for: id(1))
        await rig.engine.start()
        let state = await rig.engine.snapshot
        #expect(state.stubborn == [id(1)])
        let centred = rig.client.frame(of: id(1))
        // The fake grows the width to the minimum and keeps the tile's height.
        #expect(centred?.size == CGSize(width: 1200, height: 1055))
        let calls = rig.client.calls.count
        // A later reflow keeps it centred and does not ask again for the same frame.
        rig.client.add(makeWindow(3))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        #expect((await rig.engine.snapshot).stubborn == [id(1)])
        // The tile changed size (two to three tiles), so it was tried once more, not in a loop.
        #expect(rig.client.calls.count <= calls + 6)
        await rig.engine.stop()
    }

    @Test func aStubbornWindowIsTriedAgainWhenItsTileChangesSize() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        rig.client.setMinimumSize(CGSize(width: 1200, height: 400), for: id(1))
        await rig.engine.start()
        #expect((await rig.engine.snapshot).stubborn == [id(1)])
        // The app now accepts small sizes and the other window closes: the tile is the whole screen.
        rig.client.setMinimumSize(CGSize(width: 100, height: 100), for: id(1))
        rig.client.remove(id(2))
        await rig.engine.ingest(.destroyed(id(2)))
        await rig.engine.settle()
        #expect((await rig.engine.snapshot).stubborn.isEmpty)
        #expect(rig.client.frame(of: id(1)) == area)
        await rig.engine.stop()
    }

    // MARK: Accessibility gate

    @Test func nothingIsArrangedWithoutAccessibility() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], canMove: { false })
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.calls.isEmpty)
        #expect(rig.client.focusCalls.isEmpty)
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(await rig.store.hidden.isEmpty)
        await rig.engine.stop()
    }

    @Test func aWindowIsArrangedOnceAccessibilityIsGranted() async throws {
        let trusted = TrustFlag(false)
        let rig = try rig([makeWindow(1), makeWindow(2)], canMove: { trusted.value })
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.calls.isEmpty)
        trusted.value = true
        // The plugin shows the current workspace again after a grant; that is what arranges.
        await rig.engine.send(.showWorkspace(ws(1)))
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        await rig.engine.stop()
    }

    // MARK: Persistence

    @Test func theTreeIsStoredAndComesBackAfterARestart() async throws {
        let first = try rig([makeWindow(1), makeWindow(2), makeWindow(3)])
        defer { first.harness.tearDown() }
        await first.engine.start()
        let tree = (await first.engine.snapshot).tiling[ws(1)]
        #expect(tree?.windows == [id(1), id(2), id(3)])
        await first.engine.stop()

        let reread = StateStore(directory: first.harness.directory)
        await reread.load()
        #expect(await reread.state.tiling[ws(1)] == tree)

        let second = try rig([makeWindow(1), makeWindow(2)], directory: first.harness)
        await second.engine.start()
        // Window 3 is gone: the restored tree was pruned to the live windows.
        #expect((await second.engine.snapshot).tiling[ws(1)]?.windows == [id(1), id(2)])
        await second.engine.stop()
    }

    @Test func aRestoredTreeKeepsItsShapeAndWeights() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let seeded = StateStore(directory: harness.directory)
        await seeded.load()
        let shaped = tree(.horizontal, [leaf(1, 3), box(.vertical, 1, [leaf(2), leaf(3)])])
        await seeded.setTiling([ws(1): shaped])
        await seeded.close()

        let rig = try rig(
            [makeWindow(1), makeWindow(2), makeWindow(3)], directory: harness)
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 0, y: 25, width: 1440, height: 1055))
        #expect(rig.client.frame(of: id(2)) == CGRect(x: 1440, y: 25, width: 480, height: 528))
        await rig.engine.stop()
    }
}

/// A flag the test flips from outside the engine's actor.
final class TrustFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool

    init(_ value: Bool) { flag = value }

    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
