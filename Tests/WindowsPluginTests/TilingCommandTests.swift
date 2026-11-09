import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The tiling commands (step 2.5) through the engine and through the plugin's command table. Engine scenarios run
/// under TSan in CI (`Tiling`).
@Suite struct TilingCommandTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

    private struct Rig {
        let harness: WindowsHarness
        let client: FakeWindowClient
        let engine: WindowEngine
    }

    /// Three windows 1, 2, 3 in one row on a 1920 wide display, the first focused, no gaps.
    private func rig(kind: LayoutKind = .tiling, count: Int = 3) async throws -> Rig {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: (1...count).map { makeWindow(UInt32($0)) })
        client.setFocused(id(1))
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        let time = ManualNow()
        var config = EngineConfig()
        config.layout = LayoutConfig(
            defaultKind: kind, innerGap: 0, outerGap: 0, rootOrientation: .horizontal, overrides: [:])
        let engine = WindowEngine(
            client: client, store: store, clock: time, workspaceCount: 4, config: config,
            tick: .milliseconds(5))
        await engine.start()
        return Rig(harness: harness, client: client, engine: engine)
    }

    private func x(_ rig: Rig, _ number: UInt32) -> CGFloat? { rig.client.frame(of: id(number))?.minX }

    // MARK: Focus

    @Test func focusMovesToTheNeighbourAndStopsAtTheEdge() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.focusDirection(.right))
        #expect(rig.client.focusCalls == [id(2)])
        #expect((await rig.engine.snapshot).focused == id(2))
        await rig.engine.send(.focusDirection(.right))
        await rig.engine.send(.focusDirection(.right))
        #expect(rig.client.focusCalls == [id(2), id(3)])
        await rig.engine.send(.focusDirection(.up))
        #expect(rig.client.focusCalls.count == 2)
        await rig.engine.stop()
    }

    // MARK: Move

    @Test func moveSwapsTheFocusedWindowWithItsNeighbour() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.moveInTree(.right))
        #expect((await rig.engine.snapshot).tiling[ws(1)]?.windows == [id(2), id(1), id(3)])
        #expect(x(rig, 2) == 0 && x(rig, 1) == 640 && x(rig, 3) == 1280)
        await rig.engine.stop()
    }

    // MARK: Resize

    @Test func growAndShrinkMoveTheShareOfTheFocusedTile() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.resize(TilingTree.resizeStep))
        #expect(rig.client.frame(of: id(1))?.width == 736)
        #expect(rig.client.frame(of: id(2))?.width == 544)
        #expect(rig.client.frame(of: id(3))?.width == 640)
        await rig.engine.send(.resize(-TilingTree.resizeStep))
        #expect(rig.client.frame(of: id(1))?.width == 640)
        await rig.engine.stop()
    }

    @Test func balanceGivesEveryTileTheSameWidthAgain() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.resize(0.2))
        #expect(rig.client.frame(of: id(1))?.width != 640)
        await rig.engine.send(.balance)
        #expect(rig.client.frame(of: id(1))?.width == 640)
        #expect(rig.client.frame(of: id(2))?.width == 640)
        await rig.engine.stop()
    }

    // MARK: Join and orientation

    @Test func joinStacksTheWindowWithItsNeighbour() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.join(.right))
        let first = try #require(rig.client.frame(of: id(1)))
        let second = try #require(rig.client.frame(of: id(2)))
        #expect(first.width == 1280 && second.width == 1280)
        #expect(first.minY == 25 && second.minY > first.minY)
        #expect(rig.client.frame(of: id(3))?.minX == 1280)
        await rig.engine.stop()
    }

    @Test func toggleOrientationStacksTheWholeRow() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.toggleOrientation)
        for number in 1...3 as ClosedRange<UInt32> { #expect(rig.client.frame(of: id(number))?.width == 1920) }
        #expect(rig.client.frame(of: id(3))?.minY ?? 0 > rig.client.frame(of: id(2))?.minY ?? 0)
        await rig.engine.stop()
    }

    // MARK: Where the commands do nothing

    @Test func aFloatingWindowIgnoresTheTilingCommands() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        await rig.engine.send(.toggleFloating)
        rig.client.clearCalls()
        let before = (await rig.engine.snapshot).tiling
        for command: EngineCommand in [
            .focusDirection(.right), .moveInTree(.right), .resize(0.05), .join(.right), .toggleOrientation, .balance,
        ] {
            await rig.engine.send(command)
        }
        #expect(rig.client.calls.isEmpty)
        #expect(rig.client.focusCalls.isEmpty)
        #expect((await rig.engine.snapshot).tiling == before)
        await rig.engine.stop()
    }

    @Test func aFreeWorkspaceIgnoresTheTilingCommands() async throws {
        let rig = try await rig(kind: .free)
        defer { rig.harness.tearDown() }
        for command: EngineCommand in [
            .focusDirection(.right), .moveInTree(.right), .resize(0.05), .join(.right), .toggleOrientation, .balance,
        ] {
            await rig.engine.send(command)
        }
        #expect(rig.client.calls.isEmpty)
        #expect(rig.client.focusCalls.isEmpty)
        #expect((await rig.engine.snapshot).tiling.isEmpty)
        await rig.engine.stop()
    }

    @Test func aStillEngineIgnoresTheTilingCommands() async throws {
        let rig = try await rig()
        defer { rig.harness.tearDown() }
        _ = await rig.engine.restoreAllWindows()
        rig.client.clearCalls()
        await rig.engine.send(.moveInTree(.right))
        await rig.engine.send(.focusDirection(.right))
        #expect(rig.client.calls.isEmpty && rig.client.focusCalls.isEmpty)
    }

    // MARK: Through the plugin

    @MainActor
    private func plugin(granted: Bool = true) async throws -> (
        WindowsPlugin, FakeWindowClient, RecordingHUD, WindowsHarness
    ) {
        let harness = try WindowsHarness()
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setDefaultKind(.tiling)
        settings.setInnerGap(0)
        settings.setOuterGap(0)
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2), makeWindow(3)])
        client.setFocused(id(1))
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: granted)), hud: hud,
            activationCenter: NotificationCenter())
        try await plugin.activate()
        return (plugin, client, hud, harness)
    }

    @MainActor
    private func run(_ plugin: WindowsPlugin, _ commandID: String) async throws {
        let command = try #require(plugin.commands.first { $0.id == commandID })
        try await command.run()
    }

    struct CommandCase: Sendable, CustomTestStringConvertible {
        var id: String
        var testDescription: String { id }
    }

    /// Every tiling command id and what it does to the three windows, in a table.
    static let table: [CommandCase] = [
        CommandCase(id: "windows.focus.right"), CommandCase(id: "windows.move.right"),
        CommandCase(id: "windows.resize.grow"), CommandCase(id: "windows.join.right"),
        CommandCase(id: "windows.toggleOrientation"), CommandCase(id: "windows.balance"),
        CommandCase(id: "windows.toggleFloating"),
    ]

    @MainActor @Test(arguments: table)
    func eachCommandChangesSomethingWithAccessibilityAndNothingWithout(_ item: CommandCase) async throws {
        let (plugin, client, _, harness) = try await plugin()
        defer { harness.tearDown() }
        client.clearCalls()
        let before = (1...3 as ClosedRange<UInt32>).map { client.frame(of: id($0)) }
        try await run(plugin, item.id)
        let after = (1...3 as ClosedRange<UInt32>).map { client.frame(of: id($0)) }
        let focused = !client.focusCalls.isEmpty
        // balance on an already balanced row is the one command that may change nothing.
        if item.id != "windows.balance" { #expect(before != after || focused) }
        await plugin.deactivate()
    }

    @MainActor @Test func withoutAccessibilityACommandShowsTheHUDAndMovesNothing() async throws {
        let (plugin, client, hud, harness) = try await plugin(granted: false)
        defer { harness.tearDown() }
        try await run(plugin, "windows.move.right")
        #expect(client.calls.isEmpty)
        #expect(client.focusCalls.isEmpty)
        #expect(hud.shown.last == .accessibilityNeeded(.moving))
        await plugin.deactivate()
    }

    @MainActor @Test func toggleLayoutCyclesThroughAutoTileZonesAndFreeThroughTheOverride() async throws {
        let (plugin, client, _, harness) = try await plugin()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        #expect(client.frame(of: id(2))?.minX == 640)
        try await run(plugin, "windows.toggleLayout")
        // Zones: the stock Columns 2 layout (landscape default), the second window in the right zone.
        #expect(settings.workspaceOverrides.byWorkspace[ws(1)]?.kind == .zones)
        try await waitUntil { client.frame(of: id(2))?.minX == 964 }
        try await run(plugin, "windows.toggleLayout")
        #expect(settings.workspaceOverrides.byWorkspace[ws(1)]?.kind == .free)
        // Free: a window moved by hand is left alone.
        client.moveBehindTheEnginesBack(id(2), to: CGRect(x: 7, y: 7, width: 300, height: 300))
        client.emit([.moved(id(2))])
        // Longer than the window in which the engine still expects its own last frame.
        try await Task.sleep(for: .milliseconds(700))
        client.clearCalls()
        try await run(plugin, "windows.workspace.1")
        #expect(client.calls.isEmpty)
        // Back to the default kind: the override disappears and the windows tile again.
        try await run(plugin, "windows.toggleLayout")
        #expect(settings.workspaceOverrides.byWorkspace[ws(1)] == nil)
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces) == "")
        try await waitUntil { client.frame(of: id(2))?.minX == 640 }
        await plugin.deactivate()
    }

    @MainActor @Test func theCycleIsAutoTileZonesFreeAndBack() {
        #expect(WindowsRuntime.nextKind(after: .tiling) == .zones)
        #expect(WindowsRuntime.nextKind(after: .zones) == .free)
        #expect(WindowsRuntime.nextKind(after: .free) == .tiling)
    }

    @MainActor @Test func toggleLayoutNeverOverwritesOverridesFromANewerVersion() async throws {
        let (plugin, _, _, harness) = try await plugin()
        defer { harness.tearDown() }
        let newer = #"{"version":9,"workspaces":{}}"#
        harness.pluginSettings.set(newer, for: WindowsSettings.Key.workspaces)
        try await run(plugin, "windows.toggleLayout")
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces) == newer)
        await plugin.deactivate()
    }
}
