import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Budgets of window management v2 Phases 1 and 2 (`docs/perf.md`). Off by default:
/// `LINTEL_BENCHMARKS=1 swift test -c release --filter ConfigureBenchmarks`. They time the pure model and the
/// reducer; the window's own first paint needs a real display and is **not** in them.
@MainActor
@Suite(
    "Configure benchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LINTEL_BENCHMARKS"] != nil))
struct ConfigureBenchmarks {
    @Test func buildingTheConfigureModel() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = ContinuousClock.now
            _ = WindowsConfigureModel(pane: plugin.paneModel, commands: { plugin.commands })
            samples.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
        }
        print("build the Configure model (rows, conflicts, keyboard check): median \(samples.sorted()[15]) ms")
    }

    @Test func accordionReflowAfterAFocusChange() {
        let order = (1...10).map { WindowID(pid: 100, number: UInt32($0)) }
        let area = CGRect(x: 0, y: 0, width: 5120, height: 1440)
        var samples: [Double] = []
        for round in 0..<200 {
            let start = ContinuousClock.now
            _ = AccordionLayout.frames(
                order: order, focused: order[round % 10], area: area, gaps: TilingGaps(inner: 10, outer: 10),
                padding: 30, orientation: .horizontal)
            samples.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
        }
        print("accordion frames for 10 windows (pure geometry): median \(samples.sorted()[100]) ms")
    }
}
