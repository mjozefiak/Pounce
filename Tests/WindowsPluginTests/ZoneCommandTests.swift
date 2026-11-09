import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The zone commands through the plugin (step 3.3): the command table, the Accessibility gate, and the
/// assignments file the runtime loads.
@Suite struct ZoneCommandTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

    @MainActor
    private func makePlugin(granted: Bool = true, assignments: String? = nil) async throws -> (
        WindowsPlugin, FakeWindowClient, RecordingHUD, WindowsHarness
    ) {
        let harness = try WindowsHarness()
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setDefaultKind(.zones)
        if let assignments {
            try Data(assignments.utf8).write(to: harness.directory.appending(path: AssignmentStore.fileName))
        }
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
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

    @MainActor @Test func theNumberedZoneCommandsAreUnboundAndHiddenFromTheMenu() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let commands = WindowsPlugin(context: harness.context()).commands
        for number in 1...9 {
            let command = try #require(commands.first { $0.id == "windows.zones.zone.\(number)" })
            #expect(command.defaultShortcut == nil)
            #expect(!command.showsInMenu)
        }
    }

    @MainActor @Test func aZoneCommandMovesTheFocusedWindow() async throws {
        let (plugin, client, _, harness) = try await makePlugin()
        defer { harness.tearDown() }
        // Columns 2 with the default gap of 8 on the main display.
        #expect(client.frame(of: id(1))?.minX == 8)
        try await run(plugin, "windows.zones.zone.2")
        #expect(client.frame(of: id(1))?.minX == 964)
        await plugin.deactivate()
    }

    @MainActor @Test func withoutAccessibilityAZoneCommandShowsTheHUDAndMovesNothing() async throws {
        let (plugin, client, hud, harness) = try await makePlugin(granted: false)
        defer { harness.tearDown() }
        try await run(plugin, "windows.zones.zone.2")
        #expect(client.calls.isEmpty)
        #expect(hud.shown.last == .accessibilityNeeded(.moving))
        await plugin.deactivate()
    }

    @MainActor @Test func theRuntimeUsesTheAssignmentsFileAndAFileThatCannotBeReadFallsBack() async throws {
        let seeded = #"{"version":1,"assignments":[{"workspace":1,"displayKey":"MAIN","layoutID":"stock.rows2"}]}"#
        let (plugin, client, _, harness) = try await makePlugin(assignments: seeded)
        #expect(client.frame(of: id(1))?.minY == 33)
        #expect(client.frame(of: id(2))?.minY ?? 0 > 500)
        #expect(client.frame(of: id(1))?.width == 1904)
        await plugin.deactivate()
        harness.tearDown()
        // An unknown layout id in the file is reported by falling back to the default of the shape.
        let unknown = #"{"version":1,"assignments":[{"workspace":1,"displayKey":"MAIN","layoutID":"user.gone"}]}"#
        let (second, secondClient, _, secondHarness) = try await makePlugin(assignments: unknown)
        defer { secondHarness.tearDown() }
        #expect(secondClient.frame(of: id(1))?.width == 948)
        await second.deactivate()
    }
}

@Suite struct ResetStateAssignmentsTests {
    @MainActor @Test func resetStateAlsoClearsTheAssignments() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.activate()
        let runtime = try #require(plugin.runtime)
        let workspace = try #require(WorkspaceID(1))
        try await runtime.assignments.set(StockLayouts.focus, workspace: workspace, displayKey: "MAIN")
        #expect(await !runtime.assignments.table.isEmpty)
        await runtime.resetState()
        #expect(await runtime.assignments.table.isEmpty)
        let reread = AssignmentStore(directory: harness.directory)
        await reread.load()
        #expect(await reread.table.isEmpty)
        await plugin.deactivate()
    }
}
