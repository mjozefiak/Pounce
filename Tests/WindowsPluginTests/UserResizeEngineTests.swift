import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// A resize by hand in the reducer and in the engine (fake client, virtual clock).
@Suite(.timeLimit(.minutes(1))) struct UserResizeEngineTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private let area = CGRect(x: 0, y: 25, width: 1920, height: 1055)
    private let t0 = 1_000.0

    private func config(kind: LayoutKind = .tiling) -> EngineConfig {
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: kind, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        return config
    }

    private func requests(_ effects: [EngineEffect]) -> [FrameRequest] {
        effects.compactMap { if case .setFrame(let request) = $0 { request } else { nil } }
    }

    /// Three tiled windows whose placements have been applied and whose echo window has passed (`t0 + 10`).
    private func settled(kind: LayoutKind = .tiling, count: Int = 3) -> EngineState {
        var state = EngineState(workspaceCount: 4)
        state.config = config(kind: kind)
        let windows = (1...count).map { makeWindow(UInt32($0)) }
        let starts = Dictionary(uniqueKeysWithValues: [(Int32(100), 1_100.0)])
        var (next, effects) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: [FakeWindowClient.mainDisplay], focused: nil, processStarts: starts, now: t0
            ))
        let results = requests(effects).map { FrameResult(request: $0, outcome: .applied($0.frame)) }
        (next, _) = EngineReducer.reduce(next, .applied(results, now: t0))
        return next
    }

    private func widened(_ state: EngineState, _ number: UInt32, by dx: CGFloat) -> CGRect {
        var frame = state.windows[id(number)]!.frame
        frame.size.width += dx
        return frame
    }

    private let later = 1_010.0

    @Test func aResizeRedistributesTheSiblingsAndLeavesTheDraggedWindowAlone() {
        let state = settled()
        let frame = widened(state, 1, by: 100)
        let (next, effects) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later))
        let asked = requests(effects)
        #expect(Set(asked.map(\.id)) == [id(2), id(3)])
        #expect(next.userResize?.window == id(1))
        #expect(asked.allSatisfy { $0.purpose == .place })
        // 590 wide each: the 100 points came half from each.
        let widths = Dictionary(uniqueKeysWithValues: asked.map { ($0.id, $0.frame.width) })
        #expect(abs((widths[id(2)] ?? 0) - 590) < 1.5)
        #expect(abs((widths[id(3)] ?? 0) - 590) < 1.5)
    }

    @Test func theSettleInputPutsTheDraggedWindowOnItsExactTile() {
        let state = settled()
        let frame = widened(state, 1, by: 100).offsetBy(dx: 0, dy: 7)
        var (next, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later))
        var effects: [EngineEffect]
        (next, effects) = EngineReducer.reduce(next, .userResizeSettled(id(1), released: true, now: later + 0.25))
        #expect(next.userResize == nil)
        let asked = requests(effects)
        #expect(asked.map(\.id) == [id(1)])
        #expect(abs(asked[0].frame.width - 740) < 1.5)
        #expect(asked[0].frame.minY == area.minY)
    }

    @Test func aSettleForAnotherWindowDoesNothing() {
        let state = settled()
        var (next, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: widened(state, 1, by: 100), now: later))
        let (after, effects) = EngineReducer.reduce(next, .userResizeSettled(id(2), released: true, now: later + 1))
        #expect(after.userResize?.window == id(1))
        #expect(requests(effects).isEmpty)
        next = after
    }

    @Test func theEchoOfOurOwnPlacementIsNotAdopted() {
        let state = settled()
        // The window was just placed: its frame is expected, and an event with it is an echo.
        let tile = state.windows[id(1)]!.frame
        let (placed, effects) = EngineReducer.reduce(
            state, .place(id(1), tile.insetBy(dx: 0, dy: 30), now: later))
        #expect(!requests(effects).isEmpty)
        let (next, again) = EngineReducer.reduce(
            placed, .windowMoved(id(1), frame: tile.insetBy(dx: 0, dy: 30), now: later + 0.1))
        #expect(next.userResize == nil)
        #expect(requests(again).isEmpty)
        #expect(next.diagnostics.echoesDropped == 1)
    }

    @Test func aWindowWithAFrameChangeInFlightIsNotAdopted() {
        let state = settled()
        // Inside the echo window of the engine's own request (an app answering with a size of its own).
        let (next, effects) = EngineReducer.reduce(
            state, .windowMoved(id(1), frame: widened(state, 1, by: 100), now: t0 + 0.2))
        #expect(next.userResize == nil)
        #expect(requests(effects).isEmpty)
    }

    @Test func aStubbornFloatingOrFrozenWindowIsNotAdopted() {
        var state = settled()
        let frame = widened(state, 1, by: 100)
        state.stubborn.insert(id(1))
        #expect(EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later)).0.userResize == nil)
        state.stubborn.removeAll()
        state.floating.insert(id(1))
        #expect(EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later)).0.userResize == nil)
        state.floating.removeAll()
        state.isFrozen = true
        #expect(EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later)).0.userResize == nil)
    }

    @Test func aKindWithoutTheCapabilityIgnoresTheResize() {
        let state = settled(kind: .free)
        let frame = widened(state, 1, by: 100)
        let (next, effects) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later))
        #expect(next.userResize == nil)
        #expect(requests(effects).isEmpty)
    }

    @Test func aPlainMoveIsNotAdopted() {
        let state = settled()
        let frame = state.windows[id(1)]!.frame.offsetBy(dx: 80, dy: 30)
        let (next, effects) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: later))
        #expect(next.userResize == nil)
        #expect(requests(effects).isEmpty)
    }

    @Test func reflowsDuringADragAreThrottledToTenPerSecond() {
        var state = settled()
        var reflows = 0
        var now = later
        var width: CGFloat = 0
        // 60 events 30 ms apart (1.8 s): the user keeps dragging the right edge.
        for _ in 0..<60 {
            width += 8
            var frame = state.windows[id(1)]!.frame
            frame.size.width = 640 + width
            let (next, effects) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: now))
            state = next
            if !requests(effects).isEmpty { reflows += 1 }
            now += 0.03
        }
        #expect(reflows >= 10 && reflows <= 20)
    }

    @Test func aPauseWithTheButtonHeldCatchesTheSiblingsUpAndLeavesTheDraggedWindowAlone() {
        let state = settled()
        var (next, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: widened(state, 1, by: 100), now: later))
        // 30 ms later, inside the throttle: adopted, but nobody moves yet.
        let wider = widened(state, 1, by: 160)
        var effects: [EngineEffect]
        (next, effects) = EngineReducer.reduce(next, .windowMoved(id(1), frame: wider, now: later + 0.03))
        #expect(requests(effects).isEmpty)
        // The user holds still with the button down: the siblings catch up, the dragged window is not touched.
        (next, effects) = EngineReducer.reduce(next, .userResizeSettled(id(1), released: false, now: later + 0.3))
        let asked = requests(effects)
        #expect(Set(asked.map(\.id)) == [id(2), id(3)])
        #expect(next.userResize?.window == id(1))
        let widths = Dictionary(uniqueKeysWithValues: asked.map { ($0.id, $0.frame.width) })
        #expect(abs((widths[id(2)] ?? 0) - 560) < 1.5)
        #expect(abs((widths[id(3)] ?? 0) - 560) < 1.5)
    }

    @Test func theReflowIntervalGrowsWithTheWindowsAReflowMoves() {
        #expect(ReducerContext.userResizeReflowInterval(moving: 0) == 0.1)
        #expect(ReducerContext.userResizeReflowInterval(moving: 3) == 0.1)
        // 8 windows, 30 frame changes a second at most: one reflow every 267 ms.
        #expect(abs(ReducerContext.userResizeReflowInterval(moving: 8) - 8.0 / 30) < 1e-9)
    }

    @Test func aDragAmongNineWindowsStaysWithinTheFrameBudget() {
        var state = settled(count: 9)
        var stamps: [Double] = []
        var now = later
        let origin = state.windows[id(1)]!.frame
        // 100 events 30 ms apart (3 s): every reflow moves the 8 other windows.
        for step in 1...100 {
            var frame = origin
            frame.size.width += CGFloat(step) * 2
            let (next, effects) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: now))
            let asked = requests(effects)
            #expect(!asked.contains { $0.id == id(1) })
            stamps += asked.map { _ in now }
            // Our own placements land, so the next event of the dragged window is compared with fresh tiles.
            let results = asked.map { FrameResult(request: $0, outcome: .applied($0.frame)) }
            (state, _) = EngineReducer.reduce(next, .applied(results, now: now))
            now += 0.03
        }
        let busiest = stamps.map { start in stamps.filter { $0 >= start && $0 < start + 1 }.count }.max() ?? 0
        // The budget holds on average; a one-second span can hold one reflow more than it.
        #expect(busiest <= Int(ReducerContext.userResizeFrameBudget) + 8)
        #expect(busiest < Watchdog.defaultLimit)
        #expect(!stamps.isEmpty)
    }

    // MARK: Engine

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let engine: WindowEngine
        let clock: VirtualClock
    }

    private func rig(windows: Int = 3, button: TrustFlag = TrustFlag(false)) throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: (1...windows).map { makeWindow(UInt32($0)) })
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let clock = VirtualClock(autoAdvance: false)
        let engine = makeEngine(
            client: client, store: store, clock: clock, workspaceCount: 4, config: config(), tick: .seconds(3600),
            leftButtonDown: { button.value })
        return Rig(harness: harness, client: client, engine: engine, clock: clock)
    }

    @Test func theEngineMovesTheSiblingsAtOnceAndSettlesTheDraggedWindowAfterAQuarterSecond() async throws {
        let rig = try rig()
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.clock.advance(5)
        let tile = try #require(rig.client.frame(of: id(1)))
        var dragged = tile
        dragged.size.width += 100
        rig.client.moveBehindTheEnginesBack(id(1), to: dragged)
        rig.client.emit([.resized(id(1))])
        await rig.engine.flushEvents()
        // Siblings follow; the dragged window keeps what the user made.
        #expect(abs((rig.client.frame(of: id(2))?.width ?? 0) - 590) < 1.5)
        #expect(rig.client.frame(of: id(1)) == dragged)
        #expect(await rig.engine.snapshot.userResize?.window == id(1))
        // 100 ms later the timer has not fired: nothing lands yet.
        rig.clock.advance(0.1)
        await rig.engine.settle()
        #expect(rig.client.frame(of: id(1)) == dragged)
        rig.clock.advance(0.25)
        // The timer's task hops onto the engine; give it the turns it needs.
        for _ in 0..<200 where await rig.engine.snapshot.userResize != nil { await Task.yield() }
        await rig.engine.settle()
        #expect(await rig.engine.snapshot.userResize == nil)
        let landed = try #require(rig.client.frame(of: id(1)))
        #expect(abs(landed.width - 740) < 1.5)
        await rig.engine.stop()
    }

    @Test func aHundredResizeEventsOverThreeSecondsNeverTripTheWatchdog() async throws {
        let rig = try rig(windows: 4)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.clock.advance(5)
        let origin = try #require(rig.client.frame(of: id(1)))
        for step in 1...100 {
            var frame = origin
            frame.size.width += CGFloat(step) * 4
            rig.client.moveBehindTheEnginesBack(id(1), to: frame)
            rig.client.emit([.resized(id(1))])
            await rig.engine.flushEvents()
            rig.clock.advance(0.03)
        }
        let state = await rig.engine.snapshot
        #expect(state.diagnostics.watchdogTrips == 0)
        #expect(!state.isFrozen)
        #expect(state.userResize != nil)
        // Siblings stayed inside the screen and kept their order.
        let frames = [2, 3, 4].compactMap { rig.client.frame(of: id(UInt32($0))) }
        #expect(frames.count == 3)
        #expect(frames.allSatisfy { $0.minX >= (rig.client.frame(of: id(1))?.minX ?? 0) })
        await rig.engine.stop()
    }

    @Test func aDragAmongNineWindowsNeverTripsTheWatchdog() async throws {
        let rig = try rig(windows: 9)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.clock.advance(5)
        let origin = try #require(rig.client.frame(of: id(1)))
        // 200 events 30 ms apart (6 s, well past the watchdog's 2 s), the edge going back and forth over 300 points:
        // every reflow moves the 8 other windows.
        for step in 1...200 {
            let phase = step % 60
            var frame = origin
            frame.size.width += CGFloat(phase < 30 ? phase : 60 - phase) * 10
            rig.client.moveBehindTheEnginesBack(id(1), to: frame)
            rig.client.emit([.resized(id(1))])
            await rig.engine.flushEvents()
            rig.clock.advance(0.03)
        }
        let state = await rig.engine.snapshot
        #expect(state.diagnostics.watchdogTrips == 0)
        #expect(!state.isFrozen)
        await rig.engine.stop()
    }

    @Test func aPauseWithTheButtonHeldNeverMovesTheDraggedWindow() async throws {
        let button = TrustFlag(true)
        let rig = try rig(button: button)
        defer { rig.harness.tearDown() }
        await rig.engine.start()
        rig.clock.advance(5)
        let tile = try #require(rig.client.frame(of: id(1)))
        // Two resizes 30 ms apart: the second is adopted inside the throttle, so the siblings lag behind it.
        var dragged = tile
        dragged.size.width += 100
        rig.client.moveBehindTheEnginesBack(id(1), to: dragged)
        rig.client.emit([.resized(id(1))])
        await rig.engine.flushEvents()
        rig.clock.advance(0.03)
        dragged.size.width += 60
        rig.client.moveBehindTheEnginesBack(id(1), to: dragged)
        rig.client.emit([.resized(id(1))])
        await rig.engine.flushEvents()
        #expect(abs((rig.client.frame(of: id(2))?.width ?? 0) - 590) < 1.5)
        // The user holds still with the button down for two seconds.
        for _ in 0..<8 {
            rig.clock.advance(0.25)
            for _ in 0..<50 { await Task.yield() }
            await rig.engine.settle()
        }
        #expect(await rig.engine.snapshot.userResize?.window == id(1))
        #expect(rig.client.frame(of: id(1)) == dragged)
        // The siblings caught up with the last size.
        #expect(abs((rig.client.frame(of: id(2))?.width ?? 0) - 560) < 1.5)
        // The button goes up: the next look ends the drag, and the window lands on its tile.
        button.value = false
        for _ in 0..<4 where await rig.engine.snapshot.userResize != nil {
            rig.clock.advance(0.25)
            for _ in 0..<50 { await Task.yield() }
            await rig.engine.settle()
        }
        #expect(await rig.engine.snapshot.userResize == nil)
        await rig.engine.stop()
    }
}

/// The system resizes windows by itself while the displays change (a fallback display after a wake): not a resize by hand.
@Suite(.timeLimit(.minutes(1))) struct DisplaySettleTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }
    private let t0 = 1_000.0
    private let placeholder = DisplayInfo(
        id: 99, uuid: "placeholder", frame: CGRect(x: 0, y: 0, width: 1280, height: 720), isMain: true)

    private func settled() -> EngineState {
        var state = EngineState(workspaceCount: 4)
        state.config.layout = LayoutConfig(
            defaultKind: .tiling, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        let windows = (1...3).map { makeWindow(UInt32($0)) }
        var (next, effects) = EngineReducer.reduce(
            state,
            .snapshot(
                windows: windows, displays: [FakeWindowClient.mainDisplay], focused: nil,
                processStarts: [100: 1_100.0], now: t0))
        let results = effects.compactMap { effect -> FrameResult? in
            if case .setFrame(let request) = effect {
                FrameResult(request: request, outcome: .applied(request.frame))
            } else {
                nil
            }
        }
        (next, _) = EngineReducer.reduce(next, .applied(results, now: t0))
        return next
    }

    private func widened(_ state: EngineState) -> CGRect {
        var frame = state.windows[id(1)]!.frame
        frame.size.width += 100
        return frame
    }

    @Test func aResizeRightAfterADisplayChangeIsNotAdoptedAndIsCounted() {
        var state = settled()
        let layouts = state.layouts
        (state, _) = EngineReducer.reduce(state, .displaysChanged([placeholder], now: t0 + 10))
        let frame = widened(state)
        let (next, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: t0 + 11))
        #expect(next.userResize == nil)
        #expect(next.layouts == layouts)
        #expect(next.diagnostics.resizesIgnoredDuringDisplaySettle == 1)
    }

    @Test func aResizeAfterTheSettleTimeIsAdopted() {
        var state = settled()
        (state, _) = EngineReducer.reduce(state, .displaysChanged([FakeWindowClient.mainDisplay], now: t0 + 10))
        let frame = widened(state)
        let at = t0 + 10 + ReducerContext.displaySettleDuration + 0.1
        let (next, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: frame, now: at))
        #expect(next.userResize?.window == id(1))
        #expect(next.diagnostics.resizesIgnoredDuringDisplaySettle == 0)
    }

    @Test func aFlapToAFallbackDisplayAndBackKeepsTheWorkspaceAndTheWeights() {
        var state = settled()
        let layouts = state.layouts
        let shown = state.model.current
        (state, _) = EngineReducer.reduce(state, .displaysChanged([placeholder], now: t0 + 10))
        let squeezed = CGRect(x: 0, y: 0, width: 400, height: 720)
        (state, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: squeezed, now: t0 + 10.5))
        (state, _) = EngineReducer.reduce(state, .displaysChanged([FakeWindowClient.mainDisplay], now: t0 + 11.7))
        (state, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: squeezed, now: t0 + 12))
        #expect(state.layouts == layouts)
        #expect(state.model.current == shown)
        #expect(state.diagnostics.resizesIgnoredDuringDisplaySettle == 2)
    }
}
