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
        (next, effects) = EngineReducer.reduce(next, .userResizeSettled(id(1), now: later + 0.25))
        #expect(next.userResize == nil)
        let asked = requests(effects)
        #expect(asked.map(\.id) == [id(1)])
        #expect(abs(asked[0].frame.width - 740) < 1.5)
        #expect(asked[0].frame.minY == area.minY)
    }

    @Test func aSettleForAnotherWindowDoesNothing() {
        let state = settled()
        var (next, _) = EngineReducer.reduce(state, .windowMoved(id(1), frame: widened(state, 1, by: 100), now: later))
        let (after, effects) = EngineReducer.reduce(next, .userResizeSettled(id(2), now: later + 1))
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

    // MARK: Engine

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let engine: WindowEngine
        let clock: VirtualClock
    }

    private func rig(windows: Int = 3) throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: (1...windows).map { makeWindow(UInt32($0)) })
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let clock = VirtualClock(autoAdvance: false)
        let engine = makeEngine(
            client: client, store: store, clock: clock, workspaceCount: 4, config: config(), tick: .seconds(3600))
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
}
