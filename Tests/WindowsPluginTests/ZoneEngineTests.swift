import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Zones in the engine (step 3.3) against the fake client: placement, stacking, the new-window rule, moves
/// between zones, the kind per workspace, the Accessibility gate and persistence. Runs under TSan in CI (`Zone`).
@Suite struct ZoneEngineTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32, pid: Int32 = 100) -> WindowID { WindowID(pid: pid, number: number) }

    /// Columns 2 with spacing 8 on the main display (visible frame 0, 25, 1920, 1055).
    private let left = CGRect(x: 8, y: 33, width: 948, height: 1039)
    private let right = CGRect(x: 964, y: 33, width: 948, height: 1039)
    private let key = "MAIN"

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let store: StateStore
        let engine: WindowEngine
    }

    private func zonesConfig(
        kind: LayoutKind = .zones, overrides: [WorkspaceID: WorkspaceOverride] = [:], zones: ZonesConfig = ZonesConfig()
    ) -> EngineConfig {
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: kind, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: overrides)
        config.zones = zones
        return config
    }

    private func rig(
        _ windows: [WindowInfo], config: EngineConfig? = nil, focused: WindowID? = nil,
        canMove: @escaping @Sendable () -> Bool = { true }, directory: WindowsHarness? = nil, count: Int = 4,
        displays: [DisplayInfo] = [FakeWindowClient.mainDisplay]
    ) throws -> Rig {
        let harness = try directory ?? WindowsHarness()
        let client = FakeWindowClient(displays: displays, windows: windows)
        client.setFocused(focused)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let time = ManualNow()
        let engine = WindowEngine(
            client: client, store: store, now: { time.now }, workspaceCount: count,
            config: config ?? zonesConfig(), tick: .milliseconds(5), canMove: canMove)
        return Rig(harness: harness, client: client, store: store, engine: engine)
    }

    private func placed(_ rig: Rig, workspace: Int = 1, display: String = "MAIN") async -> [WindowID: Int] {
        (await rig.engine.state).zones[ws(workspace)]?[display]?.zoneOf ?? [:]
    }

    // MARK: Placement

    @Test func windowsFillTheZonesInJoinOrder() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1)) == left)
        #expect(rig.client.frame(of: id(2)) == right)
        #expect(await placed(rig) == [id(1): 1, id(2): 2])
        await rig.engine.stop()
    }

    @Test func aWindowWhenEveryZoneIsTakenStacksInTheFocusedZone() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(2))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.add(makeWindow(3))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        #expect(rig.client.frame(of: id(3)) == right)
        #expect(rig.client.frame(of: id(2)) == right)
        #expect(await placed(rig) == [id(1): 1, id(2): 2, id(3): 2])
        await rig.engine.stop()
    }

    @Test func aNewWindowTakesTheFirstEmptyZoneAfterAWindowClosed() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.remove(id(1))
        await rig.engine.ingest(.destroyed(id(1)))
        await rig.engine.settle()
        rig.client.add(makeWindow(3))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        // The survivor keeps its zone; the newcomer takes the free one.
        #expect(await placed(rig) == [id(2): 2, id(3): 1])
        #expect(rig.client.frame(of: id(3)) == left)
        await rig.engine.stop()
    }

    @Test func aNewWindowOfAnAppGoesToWhereThatAppLastWasWhenItIsEmpty() async throws {
        let rig = try rig([makeWindow(1, bundleID: "app.a"), makeWindow(2, bundleID: "app.b")])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.remove(id(1))
        rig.client.remove(id(2))
        await rig.engine.ingest(.destroyed(id(1)))
        await rig.engine.ingest(.destroyed(id(2)))
        await rig.engine.settle()
        // Both zones are empty: app.b's window sat in zone 2, so its next window goes there, not to zone 1.
        rig.client.add(makeWindow(3, bundleID: "app.b"))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        #expect(await placed(rig) == [id(3): 2])
        #expect(rig.client.frame(of: id(3)) == right)
        await rig.engine.stop()
    }

    @Test func theRememberedZoneIsIgnoredWhenItIsTaken() async throws {
        let rig = try rig([makeWindow(1, bundleID: "app.a"), makeWindow(2, bundleID: "app.b")])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.client.remove(id(1))
        await rig.engine.ingest(.destroyed(id(1)))
        await rig.engine.settle()
        // app.a last was in zone 1, which is empty: it goes back there.
        rig.client.add(makeWindow(3, bundleID: "app.a"))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        #expect(await placed(rig) == [id(2): 2, id(3): 1])
        // app.b last was in zone 2, which is taken: the first empty zone is none, so it stacks with the focus.
        rig.client.add(makeWindow(4, bundleID: "app.b"))
        await rig.engine.ingest(.created(id(4)))
        await rig.engine.settle()
        #expect(await placed(rig)[id(4)] != nil)
        await rig.engine.stop()
    }

    @Test func floatingWindowsAreNeitherPlacedNorMoved() async throws {
        var config = zonesConfig()
        config.floatingBundleIDs = ["com.example.float"]
        let rig = try rig([makeWindow(1), makeWindow(2, bundleID: "com.example.float")], config: config)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(2)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(await placed(rig) == [id(1): 1])
        await rig.engine.stop()
    }

    // MARK: Moving between zones

    @Test func aWindowMovesToANumberedZone() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveToZone(2))
        #expect(await placed(rig) == [id(1): 2, id(2): 2])
        #expect(rig.client.frame(of: id(1)) == right)
        // A zone the layout does not have is ignored.
        await rig.engine.send(.moveToZone(5))
        #expect(await placed(rig)[id(1)] == 2)
        await rig.engine.stop()
    }

    @Test func aWindowMovesToTheNeighbouringZoneAndStopsAtTheEdge() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveInTree(.left))
        #expect(await placed(rig)[id(1)] == 1)
        await rig.engine.send(.moveInTree(.right))
        #expect(await placed(rig)[id(1)] == 2)
        await rig.engine.send(.moveInTree(.right))
        #expect(await placed(rig)[id(1)] == 2)
        await rig.engine.send(.moveInTree(.up))
        #expect(await placed(rig)[id(1)] == 2)
        await rig.engine.stop()
    }

    @Test func focusGoesToAWindowOfTheNeighbouringZone() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.focusDirection(.right))
        #expect(rig.client.focusCalls == [id(2)])
        #expect((await rig.engine.state).focused == id(2))
        await rig.engine.send(.focusDirection(.right))
        #expect(rig.client.focusCalls == [id(2)])
        await rig.engine.stop()
    }

    @Test func aWindowIsSnappedToAZoneOfItsDisplayOnly() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.snapToZone(id(1), zone: 2, displayKey: key))
        #expect(await placed(rig)[id(1)] == 2)
        #expect(rig.client.frame(of: id(1)) == right)
        await rig.engine.send(.snapToZone(id(1), zone: 1, displayKey: "SOMEWHERE ELSE"))
        #expect(await placed(rig)[id(1)] == 2)
        await rig.engine.stop()
    }

    // MARK: The kind of a workspace

    @Test func zoneCommandsDoNothingOnAnAutoTileWorkspace() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], config: zonesConfig(kind: .tiling), focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveToZone(2))
        #expect((await rig.engine.state).zones.isEmpty)
        // The tree arranged them, not zones.
        #expect(rig.client.frame(of: id(1))?.width == 960)
        await rig.engine.stop()
    }

    @Test func aFreeWorkspaceIsNeverArranged() async throws {
        let rig = try rig([makeWindow(1)], config: zonesConfig(kind: .free), focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveToZone(1))
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect((await rig.engine.state).zones.isEmpty)
        await rig.engine.stop()
    }

    @Test func eachWorkspaceHasItsOwnKind() async throws {
        let overrides = [ws(2): WorkspaceOverride(kind: .zones)]
        let rig = try rig(
            [makeWindow(1), makeWindow(2)], config: zonesConfig(kind: .tiling, overrides: overrides), focused: id(1))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveFocusedWindow(to: ws(2)))
        await rig.engine.send(.showWorkspace(ws(2)))
        #expect(rig.client.frame(of: id(1)) == left)
        #expect(await placed(rig, workspace: 2)[id(1)] == 1)
        await rig.engine.stop()
    }

    // MARK: Accessibility gate

    @Test func nothingMovesWithoutAccessibility() async throws {
        let rig = try rig([makeWindow(1), makeWindow(2)], focused: id(1), canMove: { false })
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        await rig.engine.send(.moveToZone(2))
        await rig.engine.send(.snapToZone(id(1), zone: 2, displayKey: key))
        #expect(rig.client.calls.isEmpty)
        #expect(rig.client.frame(of: id(1)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        await rig.engine.stop()
    }

    // MARK: Layout changes

    @Test func aWindowWhoseZoneVanishedIsPlacedAgain() async throws {
        var zones = ZonesConfig()
        zones.assignments.set(StockLayouts.columns3, workspace: ws(1), displayKey: DisplayKeys.landscape)
        let rig = try rig([makeWindow(1), makeWindow(2), makeWindow(3)], config: zonesConfig(zones: zones))
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(await placed(rig) == [id(1): 1, id(2): 2, id(3): 3])
        zones.assignments.set(StockLayouts.columns2, workspace: ws(1), displayKey: DisplayKeys.landscape)
        await rig.engine.update(config: zonesConfig(zones: zones))
        // Zones 1 and 2 exist in both layouts, so those windows stay; the third has no zone 3 any more.
        let after = await placed(rig)
        #expect(after[id(1)] == 1 && after[id(2)] == 2)
        #expect(after[id(3)] != nil && after[id(3)] != 3)
        #expect(rig.client.frame(of: id(1)) == left)
        await rig.engine.stop()
    }

    @Test func aPortraitDisplayUsesTheRowsDefault() async throws {
        let portrait = DisplayInfo(
            id: 1, uuid: "TALL", frame: CGRect(x: 0, y: 0, width: 1000, height: 2000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 2000), isMain: true)
        let rig = try rig([makeWindow(1), makeWindow(2)], displays: [portrait])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        #expect(rig.client.frame(of: id(1))?.width == 984)
        #expect(rig.client.frame(of: id(1))?.minY == 8)
        #expect(rig.client.frame(of: id(2))?.minY ?? 0 > 900)
        await rig.engine.stop()
    }

    @Test func anAssignmentIsKeptPerDisplay() async throws {
        var zones = ZonesConfig()
        zones.assignments.set(StockLayouts.focus, workspace: ws(2), displayKey: "SECOND")
        let rig = try rig(
            [makeWindow(1), makeWindow(2)], config: zonesConfig(zones: zones),
            displays: [FakeWindowClient.mainDisplay, FakeWindowClient.secondDisplay])
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        // Workspace 2 is shown on the second display, which has a Focus layout: one big zone there.
        #expect(await placed(rig, workspace: 2, display: "SECOND").count == 0)
        rig.client.add(makeWindow(3, frame: CGRect(x: 2000, y: 100, width: 500, height: 500)))
        await rig.engine.ingest(.created(id(3)))
        await rig.engine.settle()
        #expect(await placed(rig, workspace: 2, display: "SECOND")[id(3)] == 1)
        #expect(rig.client.frame(of: id(3)) == CGRect(x: 1928, y: 33, width: 1904, height: 1039))
        await rig.engine.stop()
    }

    // MARK: Persistence

    @Test func theZonePlacementIsStoredAndRestored() async throws {
        let first = try rig([makeWindow(1), makeWindow(2)], focused: id(1))
        defer { first.harness.tearDown() }
        await first.engine.start()
        await first.engine.send(.moveToZone(2))
        await first.engine.stop()
        let reread = StateStore(directory: first.harness.directory)
        await reread.load()
        #expect(await reread.state.zones[ws(1)]?[key]?.zoneOf == [id(1): 2, id(2): 2])

        let second = try rig([makeWindow(1), makeWindow(2)], directory: first.harness)
        await second.engine.start()
        #expect(await placed(second) == [id(1): 2, id(2): 2])
        #expect(second.client.frame(of: id(1)) == right)
        await second.engine.stop()
    }

    @Test func storedPlacementOfGoneWindowsIsPrunedAndNoTitleIsStored() async throws {
        let first = try rig([makeWindow(1), makeWindow(2)])
        defer { first.harness.tearDown() }
        await first.engine.start()
        await first.engine.stop()
        let second = try rig([makeWindow(1)], directory: first.harness)
        await second.engine.start()
        #expect(await placed(second) == [id(1): 1])
        await second.engine.stop()
        let text = try String(contentsOf: first.harness.directory.appending(path: "state.json"), encoding: .utf8)
        #expect(!text.contains("secret title"))
        #expect(!text.contains("com.example.app"))
    }

    @Test func aZonesRecordThatDoesNotDecodeIsDroppedNotCorrupt() throws {
        let json = #"{"version":1,"workspaces":{"1":{"order":[],"zones":"nonsense"}},"hidden":[]}"#
        guard case .current(let file) = StateStore.decode(Data(json.utf8)) else {
            Issue.record("a bad zones value must not make the file corrupt")
            return
        }
        #expect(file.state.zones.isEmpty)
    }
}

/// The strategy on plain values (step 3.3).
@Suite struct ZonesStrategyTests {
    private func win(_ number: UInt32) -> WindowID { WindowID(pid: 1, number: number) }
    private let strategy = ZonesStrategy(layout: StockLayouts.layout(StockLayouts.grid2x2) ?? StockLayouts.all[0])

    @Test func placingGoesToThePreferredEmptyZoneThenTheFirstEmptyThenTheAnchor() {
        var state = strategy.emptyState
        state = strategy.placing(win(1), preferred: 3, anchor: nil, into: state)
        #expect(state.zoneOf[win(1)] == 3)
        state = strategy.placing(win(2), preferred: 3, anchor: nil, into: state)
        #expect(state.zoneOf[win(2)] == 1)
        state = strategy.placing(win(3), preferred: 99, anchor: nil, into: state)
        #expect(state.zoneOf[win(3)] == 2)
        state = strategy.placing(win(4), preferred: nil, anchor: nil, into: state)
        #expect(state.zoneOf[win(4)] == 4)
        // Everything is taken: the zone of the anchor, else the first zone.
        state = strategy.placing(win(5), preferred: nil, anchor: win(3), into: state)
        #expect(state.zoneOf[win(5)] == 2)
        state = strategy.placing(win(6), preferred: nil, anchor: nil, into: state)
        #expect(state.zoneOf[win(6)] == 1)
    }

    @Test func prunedDropsGoneWindowsAndWindowsInMissingZones() {
        var state = ZoneState(zoneOf: [win(1): 1, win(2): 2, win(3): 9])
        state = strategy.pruned(state, keeping: [win(1), win(3)])
        #expect(state.zoneOf == [win(1): 1])
    }

    @Test func movingNeedsAKnownWindowAndAnExistingZone() {
        let state = ZoneState(zoneOf: [win(1): 1])
        #expect(strategy.moving(win(1), toZone: 4, in: state).zoneOf[win(1)] == 4)
        #expect(strategy.moving(win(1), toZone: 9, in: state) == state)
        #expect(strategy.moving(win(2), toZone: 1, in: state) == state)
    }

    @Test func framesGiveEveryWindowItsZoneFrame() {
        let state = ZoneState(zoneOf: [win(1): 1, win(2): 1, win(3): 4])
        let frames = strategy.frames(
            state: state, area: CGRect(x: 0, y: 0, width: 1000, height: 600), geometry: LayoutGeometry(gaps: .none))
        #expect(frames[win(1)] == frames[win(2)])
        #expect(frames[win(3)] == CGRect(x: 504, y: 304, width: 488, height: 288))
    }

    @Test func theKindIsZonesAndWindowsListByZoneNumber() {
        #expect(ZonesStrategy.kind == "zones")
        let state = ZoneState(zoneOf: [win(1): 3, win(2): 1, win(3): 1])
        #expect(strategy.windows(in: state) == [win(2), win(3), win(1)])
        #expect(strategy.removing(win(2), from: state).zoneOf[win(2)] == nil)
    }

    @Test func theRecordRoundTrips() {
        let zones = ["A": ZoneState(zoneOf: [win(1): 2, win(2): 1]), "B": ZoneState(zoneOf: [win(3): 4])]
        #expect(ZonesRecord(zones).zones == zones)
        #expect(ZonesRecord(["": ZoneState(zoneOf: [win(1): 1])]).zones.isEmpty)
    }
}
