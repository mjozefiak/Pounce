import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Budgets for the zone phase (step 3.7, `docs/perf.md`). Off by default: `LINTEL_BENCHMARKS=1 swift test -c release
/// --filter ZoneBenchmarks`. They measure the engine and the pure parts against the fake client, so the cost of the
/// Accessibility calls and of the real panels is **not** in them; the budgets in the spec (overlay under 50 ms,
/// reflow under 30 ms) need a real Mac.
@Suite(
    "Zone benchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LINTEL_BENCHMARKS"] != nil))
struct ZoneBenchmarks {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: Int32(100 + number % 5), number: number) }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    @Test func aZoneReflowAfterOneWindowEvent() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: (1...10).map { makeWindow($0, pid: Int32(100 + $0 % 5)) })
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: .zones, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        config.zones.defaultLandscape = StockLayouts.grid2x2
        let engine = makeEngine(
            client: client, store: StateStore(directory: harness.directory, saveDelay: .seconds(3600)),
            config: config, tick: .milliseconds(1))
        await engine.start()
        var samples: [Double] = []
        for round in 0..<30 {
            let window = id(UInt32(100 + round))
            client.add(makeWindow(window.number, pid: window.pid))
            let start = ContinuousClock.now
            await engine.ingest(.created(window))
            await engine.settle()
            samples.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
            client.remove(window)
            await engine.ingest(.destroyed(window))
            await engine.settle()
        }
        print("zones reflow after one window event (engine + fake client, 10 windows): median \(median(samples)) ms")
        await engine.stop()
    }

    @Test func theOverlayDataAndTheDragMachine() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: .zones, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        let engine = makeEngine(
            client: client, store: StateStore(directory: harness.directory, saveDelay: .seconds(3600)),
            config: config, tick: .milliseconds(1))
        await engine.start()
        var samples: [Double] = []
        for _ in 0..<200 {
            let start = ContinuousClock.now
            let displays = await engine.dragDisplays(for: id(1))
            var machine = ZoneDragMachine()
            let sample = PointerSample(leftButtonDown: true, shiftDown: true, cursor: CGPoint(x: 300, y: 300))
            _ = machine.handle(.windowMoved(id(1), sample))
            _ = machine.handle(.displays(displays))
            for step in 0..<60 {
                _ = machine.handle(
                    .pointer(
                        PointerSample(
                            leftButtonDown: true, shiftDown: true, cursor: CGPoint(x: 300 + step * 20, y: 300))))
            }
            samples.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
        }
        print("zone targets plus 60 drag samples (pure, no panels): median \(median(samples)) ms")
        await engine.stop()
    }
}
