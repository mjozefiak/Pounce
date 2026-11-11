import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Phase 0, steps 0.1 (b) and 0.3: a shortcut that acts on the focused window goes through `PluginCommand.run`, the
/// same entry point as the keyboard, with the real engine over a fake client.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct FocusReadTests {
    private let home = CGRect(x: 100, y: 100, width: 800, height: 600)
    private let parkedOrigin = CGPoint(x: 1919, y: 1079)

    private func plugin(
        windows: [WindowInfo] = [makeWindow(1), makeWindow(2)]
    ) async throws -> (WindowsPlugin, FakeWindowClient, RecordingHUD, WindowsHarness) {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: windows)
        client.setFocused(windows.first?.id)
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)), hud: hud,
            activationCenter: NotificationCenter())
        try await plugin.activate()
        return (plugin, client, hud, harness)
    }

    private func run(_ plugin: WindowsPlugin, _ id: String) async throws {
        try await #require(plugin.commands.first { $0.id == id }).run()
        await plugin.runtime?.settle()
    }

    private func workspace(of window: WindowID, in plugin: WindowsPlugin) async throws -> WorkspaceID? {
        try await #require(plugin.runtime).engine.inspect { $0.model.workspace(of: window) }
    }

    /// The scenario of the report: a switch, then the move shortcut. The system still names the window the switch
    /// parked (a parked window keeps the app's focus), and nothing may move.
    @Test func theMoveShortcutRightAfterASwitchMovesNothing() async throws {
        let (plugin, client, hud, harness) = try await plugin()
        defer { harness.tearDown() }
        try await run(plugin, "windows.workspace.2")
        try await run(plugin, "windows.moveToWorkspace.3")
        #expect(try await workspace(of: WindowID(pid: 100, number: 1), in: plugin) == WorkspaceID(1))
        #expect(try await workspace(of: WindowID(pid: 100, number: 2), in: plugin) == WorkspaceID(1))
        #expect(client.frame(of: WindowID(pid: 100, number: 1))?.origin == parkedOrigin)
        #expect(hud.shown.last == .noFocusedWindow)
        await plugin.deactivate()
    }

    @Test func theCommandActsOnTheWindowTheSystemHasFocusedNotOnTheEnginesBelief() async throws {
        let (plugin, client, _, harness) = try await plugin()
        defer { harness.tearDown() }
        // The engine believes 1 is focused (its snapshot); the system now says 2 and no event arrived.
        client.setFocused(WindowID(pid: 100, number: 2))
        try await run(plugin, "windows.moveToWorkspace.3")
        #expect(try await workspace(of: WindowID(pid: 100, number: 2), in: plugin) == WorkspaceID(3))
        #expect(try await workspace(of: WindowID(pid: 100, number: 1), in: plugin) == WorkspaceID(1))
        let diagnostics = try await #require(plugin.runtime).engine.diagnostics()
        #expect(diagnostics.focusMismatches == 1)
        await plugin.deactivate()
    }

    @Test func aSwitchFollowedByAMoveActsOnTheWindowTheEngineFocusedNotOnAParkedOne() async throws {
        let (plugin, client, _, harness) = try await plugin(windows: [makeWindow(1), makeWindow(2)])
        defer { harness.tearDown() }
        // Window 2 goes to workspace 2, then the user goes there: the engine focuses it.
        client.setFocused(WindowID(pid: 100, number: 2))
        try await run(plugin, "windows.moveToWorkspace.2")
        try await run(plugin, "windows.workspace.2")
        #expect(client.focusCalls.last == WindowID(pid: 100, number: 2))
        // The system has not caught up: it still reports window 1, which is parked now.
        client.setFocused(WindowID(pid: 100, number: 1))
        try await run(plugin, "windows.moveToWorkspace.4")
        #expect(try await workspace(of: WindowID(pid: 100, number: 2), in: plugin) == WorkspaceID(4))
        #expect(try await workspace(of: WindowID(pid: 100, number: 1), in: plugin) == WorkspaceID(1))
        await plugin.deactivate()
    }

    @Test func aFocusReadThatDoesNotAnswerRefusesTheMoveAndIsCounted() async throws {
        let (plugin, client, hud, harness) = try await plugin()
        defer { harness.tearDown() }
        client.holdFocusReads()
        let baseSleepers = harness.clock.sleeperCount
        let command = try #require(plugin.commands.first { $0.id == "windows.moveToWorkspace.3" })
        let running = Task { @MainActor in await command.run() }
        // The read is waiting; the deadline is on the plugin's clock.
        await harness.clock.waitForSleepers(baseSleepers + 1)
        harness.clock.advance(0.26)
        await running.value
        client.releaseFocusReads()
        await plugin.runtime?.settle()
        #expect(try await workspace(of: WindowID(pid: 100, number: 1), in: plugin) == WorkspaceID(1))
        #expect(hud.shown.last == .noFocusedWindow)
        let diagnostics = try await #require(plugin.runtime).engine.diagnostics()
        #expect(diagnostics.focusReadTimeouts == 1)
        await plugin.deactivate()
    }

    @Test func aFocusReadThatAnswersNoWindowRefusesTheMoveWithoutCountingATimeout() async throws {
        let (plugin, client, hud, harness) = try await plugin()
        defer { harness.tearDown() }
        // The frontmost app has no window the engine manages (Finder, Lintel itself): an answer, not a timeout.
        client.setFocused(nil)
        try await run(plugin, "windows.moveToWorkspace.3")
        #expect(try await workspace(of: WindowID(pid: 100, number: 1), in: plugin) == WorkspaceID(1))
        #expect(hud.shown.last == .noFocusedWindow)
        let diagnostics = try await #require(plugin.runtime).engine.diagnostics()
        #expect(diagnostics.focusReadTimeouts == 0)
        await plugin.deactivate()
    }

    @Test func aWorkspaceSwitchNeverReadsTheFocus() async throws {
        let (plugin, client, _, harness) = try await plugin()
        defer { harness.tearDown() }
        let before = client.focusReads
        try await run(plugin, "windows.workspace.2")
        #expect(client.focusReads == before)
        await plugin.deactivate()
    }

    @Test func theDiagnosticsNameTheFocusCounters() {
        var counters = EngineDiagnostics()
        counters.focusMismatches = 3
        counters.focusReadTimeouts = 2
        let text = WindowsDiagnostics.report(
            counters, recoveredWindows: 0, parkedWindows: 0, workspaceCount: 9, accessibilityTrusted: true)
        #expect(text.contains("Focus mismatches: 3"))
        #expect(text.contains("Focus read timeouts: 2"))
    }
}
