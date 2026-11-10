import CoreGraphics
import Foundation
import LintelKit
import Synchronization
import Testing

@testable import WindowsPlugin

/// The overlay's geometry and the drag controller with scripted pointer, ticker and presenter (step 3.5b).
/// The panels themselves and the real pointer are manual QA items (`docs/qa.md`).
@Suite(.timeLimit(.minutes(1))) struct ScreenSpaceTests {
    @Test func pointsAndRectanglesConvertBothWays() {
        #expect(ScreenSpace.axPoint(fromCocoa: CGPoint(x: 100, y: 1000), mainHeight: 1080) == CGPoint(x: 100, y: 80))
        let ax = CGRect(x: 10, y: 20, width: 300, height: 200)
        let cocoa = ScreenSpace.cocoaRect(fromAX: ax, mainHeight: 1080)
        #expect(cocoa == CGRect(x: 10, y: 860, width: 300, height: 200))
        #expect(ScreenSpace.axRect(fromCocoa: cocoa, mainHeight: 1080) == ax)
    }

    @Test func aDisplayAboveTheMainOneIsFoundInCocoaSpace() {
        // Main 1920x1080 at the origin; a second display above it (Cocoa y from 1080 up to 2160). In the
        // Accessibility space that display has negative y.
        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 0, y: 1080, width: 1920, height: 1080)]
        let above = CGRect(x: 100, y: -900, width: 800, height: 600)
        #expect(ScreenSpace.screenIndex(forAX: above, screenFrames: frames, mainHeight: 1080) == 1)
        let main = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(ScreenSpace.screenIndex(forAX: main, screenFrames: frames, mainHeight: 1080) == 0)
        #expect(
            ScreenSpace.screenIndex(
                forAX: CGRect(x: 9000, y: 9000, width: 10, height: 10), screenFrames: frames, mainHeight: 1080) == nil)
    }

    @Test func aZoneIsPlacedRelativeToThePanelOfItsScreen() {
        // The second display is to the right of the main one and as tall: its top left is (1920, 0) in AX space.
        let screen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let zone = CGRect(x: 1928, y: 33, width: 948, height: 1039)
        #expect(
            ScreenSpace.localRect(zone, screenFrame: screen, mainHeight: 1080)
                == CGRect(x: 8, y: 33, width: 948, height: 1039))
        // A screen above the main one: its AX origin is (0, -1080).
        let above = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let upper = CGRect(x: 8, y: -1047, width: 948, height: 1039)
        #expect(
            ScreenSpace.localRect(upper, screenFrame: above, mainHeight: 1080)
                == CGRect(x: 8, y: 33, width: 948, height: 1039))
    }
}

@MainActor
private final class ScriptedPointer: PointerSampling {
    var current = PointerSample(leftButtonDown: true, shiftDown: true, cursor: CGPoint(x: 100, y: 100))
    private(set) var samples = 0
    func sample() -> PointerSample {
        samples += 1
        return current
    }
}

@MainActor
private final class SnapLog {
    var list: [String] = []
}

@MainActor
private final class ManualTicker: DragTicking {
    private var fire: (@MainActor () -> Void)?
    private(set) var isRunning = false
    func start(_ fire: @escaping @MainActor () -> Void) {
        self.fire = fire
        isRunning = true
    }
    func stop() {
        fire = nil
        isRunning = false
    }
    func tick() { fire?() }
}

@MainActor
private final class FakeOverlay: ZoneOverlayPresenting {
    private(set) var log: [String] = []
    private(set) var highlighted: DragZone?
    private(set) var visible = false
    func show(_ displays: [DragDisplay]) {
        visible = true
        log.append("show \(displays.count)")
    }
    func highlight(_ zone: DragZone?) {
        highlighted = zone
        log.append("highlight \(zone?.number ?? 0)")
    }
    func hide() {
        visible = false
        log.append("hide")
    }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct ZoneDragControllerTests {
    private let window = WindowID(pid: 1, number: 1)
    private let left = DragZone(
        displayKey: "A", zoneID: 1, number: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 600))
    private let right = DragZone(
        displayKey: "A", zoneID: 2, number: 2, frame: CGRect(x: 510, y: 0, width: 490, height: 600))

    private struct Rig {
        let pointer = ScriptedPointer()
        let ticker = ManualTicker()
        let overlay = FakeOverlay()
        let snaps = SnapLog()
        var controller: ZoneDragController?
    }

    private func rig(targets: [DragDisplay]? = nil) -> Rig {
        var rig = Rig()
        let zones =
            targets ?? [
                DragDisplay(key: "A", area: CGRect(x: 0, y: 0, width: 1000, height: 600), zones: [left, right])
            ]
        let snaps = rig.snaps
        rig.controller = ZoneDragController(
            sampler: rig.pointer, presenter: rig.overlay, ticker: rig.ticker,
            targets: { _ in zones },
            snap: { id, zone in snaps.list.append("\(id.number)->\(zone.number)") })
        return rig
    }

    @Test func nothingRunsWhileNoWindowIsDragged() {
        let rig = rig()
        #expect(rig.controller?.phase == .idle)
        #expect(!rig.ticker.isRunning)
        rig.ticker.tick()
        #expect(rig.pointer.samples == 0)
    }

    @Test func aDragWithShiftShowsTheOverlayHighlightsAndSnapsOnRelease() async {
        let rig = rig()
        rig.controller?.windowMoved(window)
        await rig.controller?.waitUntilIdle()
        #expect(rig.ticker.isRunning)
        #expect(rig.overlay.visible)
        #expect(rig.overlay.highlighted == left)
        // The cursor moves to the right zone, the timer notices.
        rig.pointer.current = PointerSample(leftButtonDown: true, shiftDown: true, cursor: CGPoint(x: 800, y: 100))
        rig.ticker.tick()
        #expect(rig.overlay.highlighted == right)
        // Release over it with Shift still held.
        rig.pointer.current = PointerSample(leftButtonDown: false, shiftDown: true, cursor: CGPoint(x: 800, y: 100))
        rig.ticker.tick()
        await rig.controller?.waitUntilIdle()
        #expect(!rig.overlay.visible)
        #expect(!rig.ticker.isRunning)
        #expect(rig.snaps.list == ["1->2"])
        #expect(rig.controller?.phase == .idle)
    }

    @Test func aDragWithoutShiftShowsNothingUntilShiftIsPressed() async {
        let rig = rig()
        rig.pointer.current = PointerSample(leftButtonDown: true, shiftDown: false, cursor: CGPoint(x: 100, y: 100))
        rig.controller?.windowMoved(window)
        await rig.controller?.waitUntilIdle()
        #expect(rig.ticker.isRunning)
        #expect(!rig.overlay.visible)
        rig.pointer.current = PointerSample(leftButtonDown: true, shiftDown: true, cursor: CGPoint(x: 100, y: 100))
        rig.ticker.tick()
        await rig.controller?.waitUntilIdle()
        #expect(rig.overlay.visible)
    }

    @Test func aMovedWindowWithTheButtonUpNeverShowsTheOverlay() async {
        let rig = rig()
        rig.pointer.current = PointerSample(leftButtonDown: false, shiftDown: true, cursor: CGPoint(x: 100, y: 100))
        rig.controller?.windowMoved(window)
        await rig.controller?.waitUntilIdle()
        #expect(!rig.overlay.visible)
        #expect(!rig.ticker.isRunning)
        #expect(rig.overlay.log.isEmpty)
    }

    @Test func noZonesToOfferMeansNoOverlay() async {
        let rig = rig(targets: [])
        rig.controller?.windowMoved(window)
        await rig.controller?.waitUntilIdle()
        #expect(!rig.overlay.visible)
        #expect(!rig.overlay.log.contains { $0.hasPrefix("show") })
    }

    @Test func cancelHidesTheOverlayAndStopsTheTimer() async {
        let rig = rig()
        rig.controller?.windowMoved(window)
        await rig.controller?.waitUntilIdle()
        rig.controller?.cancel()
        #expect(!rig.overlay.visible)
        #expect(!rig.ticker.isRunning)
        #expect(rig.snaps.list.isEmpty)
    }

    @Test func releasingShiftFirstHidesTheOverlayAndDoesNotSnap() async {
        let rig = rig()
        rig.controller?.windowMoved(window)
        await rig.controller?.waitUntilIdle()
        rig.pointer.current = PointerSample(leftButtonDown: true, shiftDown: false, cursor: CGPoint(x: 800, y: 100))
        rig.ticker.tick()
        #expect(!rig.overlay.visible)
        rig.pointer.current = PointerSample(leftButtonDown: false, shiftDown: false, cursor: CGPoint(x: 800, y: 100))
        rig.ticker.tick()
        await rig.controller?.waitUntilIdle()
        #expect(rig.snaps.list.isEmpty)
        #expect(!rig.ticker.isRunning)
    }
}

/// The engine tells the drag detector about moves of managed windows of Zones workspaces only (step 3.5b).
@Suite(.timeLimit(.minutes(1))) struct ZoneDragSignalTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

    private func run(
        kind: LayoutKind, canMove: @escaping @Sendable () -> Bool = { true },
        body: (WindowEngine, FakeWindowClient) async -> Void
    ) async throws -> [WindowID] {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        let moved = Mutex<[WindowID]>([])
        let frames = Mutex<[CGRect]>([])
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: kind, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        let time = ManualNow()
        let engine = makeEngine(
            client: client, store: StateStore(directory: harness.directory, saveDelay: .seconds(3600)),
            clock: time, config: config, tick: .milliseconds(5),
            reporter: EngineReporter(windowMoved: { id, frame in
                moved.withLock { $0.append(id) }
                frames.withLock { $0.append(frame) }
            }), canMove: canMove)
        await engine.start()
        await body(engine, client)
        await engine.stop()
        return moved.withLock { $0 }
    }

    private func dragWindow(_ engine: WindowEngine, _ client: FakeWindowClient) async {
        client.moveBehindTheEnginesBack(id(1), to: CGRect(x: 300, y: 300, width: 400, height: 400))
        await engine.ingest(.moved(id(1)))
        await engine.settle()
    }

    @Test func aMovedWindowOfAZonesWorkspaceIsReported() async throws {
        let moved = try await run(kind: .zones) { await dragWindow($0, $1) }
        #expect(moved == [id(1)])
    }

    @Test func autoTileAndFreeWorkspacesReportNothing() async throws {
        #expect(try await run(kind: .tiling) { await dragWindow($0, $1) }.isEmpty)
        #expect(try await run(kind: .free) { await dragWindow($0, $1) }.isEmpty)
    }

    @Test func theEnginesOwnEchoIsNotReported() async throws {
        let moved = try await run(kind: .zones) { engine, client in
            // The engine placed the windows at start; the client echoes that frame back.
            await engine.ingest(.moved(id(1)))
            await engine.settle()
            _ = client
        }
        #expect(moved.isEmpty)
    }

    @Test func nothingIsReportedWithoutAccessibility() async throws {
        let moved = try await run(kind: .zones, canMove: { false }, body: { await dragWindow($0, $1) })
        #expect(moved.isEmpty)
    }

    @Test func dragDisplaysOfferTheLayoutOfTheDisplayThatShowsTheWindow() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: .zones, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        let engine = makeEngine(
            client: client, store: StateStore(directory: harness.directory, saveDelay: .seconds(3600)),
            config: config, tick: .milliseconds(5))
        await engine.start()
        let displays = await engine.dragDisplays(for: id(1))
        #expect(displays.count == 1)
        #expect(displays.first?.key == "MAIN")
        #expect(displays.first?.zones.map(\.number) == [1, 2])
        #expect(displays.first?.zones.first?.frame == CGRect(x: 8, y: 33, width: 948, height: 1039))
        #expect(await engine.dragDisplays(for: id(99)).isEmpty)
        await engine.send(.restoreAll)
        #expect(await engine.dragDisplays(for: id(1)).isEmpty)
        await engine.stop()
    }
}

@Suite(.timeLimit(.minutes(1))) struct SnapHintTests {
    @MainActor @Test func theHintIsShownOnceWhenAZonesLayoutIsFirstActive() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setDefaultKind(.zones)
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)), hud: hud,
            activationCenter: NotificationCenter())
        try await plugin.activate()
        await plugin.runtime?.settle()
        #expect(hud.shown.contains(.snapHint))
        #expect(settings.snapHintShown)
        #expect(WindowsHUDState.snapHint.title == "Hold ⇧ while dragging to snap")
        await plugin.deactivate()
        // A second activation does not show it again.
        let again = RecordingHUD()
        let second = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)), hud: again,
            activationCenter: NotificationCenter())
        try await second.activate()
        await second.runtime?.settle()
        #expect(!again.shown.contains(.snapHint))
        await second.deactivate()
    }

    @MainActor @Test func noHintWithoutAZonesLayoutOrWithoutAccessibility() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)), hud: hud,
            activationCenter: NotificationCenter())
        try await plugin.activate()
        await plugin.runtime?.settle()
        #expect(!hud.shown.contains(.snapHint))
        await plugin.deactivate()
        let denied = try WindowsHarness()
        defer { denied.tearDown() }
        WindowsSettings(denied.pluginSettings).setDefaultKind(.zones)
        let deniedHUD = RecordingHUD()
        let second = WindowsPlugin(
            context: denied.context(windows: client, permissions: ScriptedPermissions(granted: false)), hud: deniedHUD,
            activationCenter: NotificationCenter())
        try await second.activate()
        await second.runtime?.settle()
        #expect(!deniedHUD.shown.contains(.snapHint))
        await second.deactivate()
    }

    @Test func theHintAndTheOverlayTextAreWordedAsTheSpecSays() {
        #expect(ZoneOverlayText.hint == "Hold ⇧ while dragging to snap")
        #expect(ZoneOverlayText.zoneName(2) == "Zone 2")
        let state = WindowsHUDState.snapHint
        #expect(!state.offersAllowAccessibility && !state.needsAttention && state.detail == nil)
    }
}
