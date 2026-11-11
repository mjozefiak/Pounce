import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The budget of the move shortcut (window management v2, Phase 0, step 0.3, `docs/perf.md`): from the focus read
/// to the last frame change of "move the focused window to workspace N". Off by default:
/// `LINTEL_BENCHMARKS=1 swift test -c release --filter FocusMoveBenchmarks`. It runs the plugin's command against
/// the fake client, so the cost of the real Accessibility calls is **not** in it.
@MainActor
@Suite(
    "Focus move benchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LINTEL_BENCHMARKS"] != nil))
struct FocusMoveBenchmarks {
    @Test func movingTheFocusedWindowToAnotherWorkspace() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let windows = (1...20).map { makeWindow($0, pid: Int32(100 + $0 % 5)) }
        let client = FakeWindowClient(windows: windows)
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.activate()
        var samples: [Double] = []
        for round in 0..<30 {
            let window = windows[round % windows.count].id
            client.setFocused(window)
            let command = try #require(plugin.commands.first { $0.id == "windows.moveToWorkspace.\(round % 8 + 2)" })
            let start = ContinuousClock.now
            await command.run()
            samples.append(Double((ContinuousClock.now - start).components.attoseconds) / 1e15)
        }
        await plugin.runtime?.settle()
        let median = samples.sorted()[samples.count / 2]
        print("move the focused window (focus read + engine + fake client, 20 windows): median \(median) ms")
        await plugin.deactivate()
    }
}
