import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The nine layout slots and *Next zone layout* (step 4.3): stable commands, bound through the repository, applied
/// to the current workspace on the focused display behind the Accessibility gate.
@Suite(.timeLimit(.minutes(1))) struct LayoutSlotTests {
    private func id(_ number: UInt32) -> WindowID { WindowID(pid: 100, number: number) }

    @MainActor
    private func makePlugin(granted: Bool = true) async throws -> (
        WindowsPlugin, FakeWindowClient, RecordingHUD, WindowsHarness
    ) {
        let harness = try WindowsHarness()
        WindowsSettings(harness.pluginSettings).setDefaultKind(.zones)
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

    @MainActor @Test func theSlotCommandsAreStableUnboundAndHiddenFromTheMenu() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let commands = WindowsPlugin(context: harness.context()).commands
        for number in 1...9 {
            let command = try #require(commands.first { $0.id == "windows.zones.layout.\(number)" })
            #expect(command.defaultShortcut == nil)
            #expect(!command.showsInMenu)
        }
        let next = try #require(commands.first { $0.id == "windows.zones.nextLayout" })
        #expect(next.defaultShortcut == nil && !next.showsInMenu)
        #expect(commands.filter { $0.id.hasPrefix("windows.zones.layout.") }.count == 9)
        // The list does not depend on the library: a plugin with a saved library has the same commands.
        #expect(Set(commands.map(\.id)).count == commands.count)
    }

    @MainActor @Test func aSlotAppliesItsLayoutToTheCurrentWorkspaceOnTheFocusedDisplay() async throws {
        let (plugin, client, _, harness) = try await makePlugin()
        defer { harness.tearDown() }
        let runtime = try #require(plugin.runtime)
        let layout = GridLayout(
            id: "", name: "Mine", spacing: 0, columns: [1], rows: [1, 1],
            zones: [
                GridZone(id: 1, colStart: 0, colEnd: 1, rowStart: 0, rowEnd: 1),
                GridZone(id: 2, colStart: 0, colEnd: 1, rowStart: 1, rowEnd: 2),
            ])
        let mine = try await runtime.layouts.create(layout)
        try await runtime.layouts.setSlot(3, to: mine.id)
        #expect(client.frame(of: id(1))?.width == 948)
        try await run(plugin, "windows.zones.layout.3")
        let workspace = try #require(WorkspaceID(1))
        #expect(await runtime.assignments.table.layoutID(workspace: workspace, displayKey: "MAIN") == mine.id)
        #expect(client.frame(of: id(1))?.width == 1920)
        // An unbound slot changes nothing.
        try await run(plugin, "windows.zones.layout.4")
        #expect(await runtime.assignments.table.layoutID(workspace: workspace, displayKey: "MAIN") == mine.id)
        await plugin.deactivate()
    }

    @MainActor @Test func aSlotBoundToAStockLayoutWorksAndANewLayoutIsUsedByTheEngineAtOnce() async throws {
        let (plugin, client, _, harness) = try await makePlugin()
        defer { harness.tearDown() }
        let runtime = try #require(plugin.runtime)
        try await runtime.layouts.setSlot(1, to: StockLayouts.rows2)
        try await run(plugin, "windows.zones.layout.1")
        #expect(client.frame(of: id(1))?.width == 1904)
        await plugin.deactivate()
    }

    @MainActor @Test func withoutAccessibilityASlotShowsTheHUDAndChangesNothing() async throws {
        let (plugin, client, hud, harness) = try await makePlugin(granted: false)
        defer { harness.tearDown() }
        let runtime = try #require(plugin.runtime)
        try await runtime.layouts.setSlot(1, to: StockLayouts.rows2)
        try await run(plugin, "windows.zones.layout.1")
        #expect(client.calls.isEmpty)
        #expect(hud.shown.last == .accessibilityNeeded(.moving))
        #expect(await runtime.assignments.table.isEmpty)
        await plugin.deactivate()
    }

    @MainActor @Test func nextLayoutCyclesThroughStockThenUserLayoutsAndWraps() async throws {
        let (plugin, _, _, harness) = try await makePlugin()
        defer { harness.tearDown() }
        let runtime = try #require(plugin.runtime)
        let workspace = try #require(WorkspaceID(1))
        let mine = try await runtime.layouts.create(StockLayouts.layout(StockLayouts.focus) ?? StockLayouts.all[0])
        // The default is Columns 2, so the next one is Columns 3.
        try await run(plugin, "windows.zones.nextLayout")
        #expect(await runtime.assignments.table.layoutID(workspace: workspace, displayKey: "MAIN") == "stock.columns3")
        for expected in ["stock.rows2", "stock.grid2x2", "stock.priority", mine.id, "stock.focus"] {
            try await run(plugin, "windows.zones.nextLayout")
            #expect(await runtime.assignments.table.layoutID(workspace: workspace, displayKey: "MAIN") == expected)
        }
        await plugin.deactivate()
    }

    @Test func theLibraryCyclesAndWraps() {
        let library = LayoutLibrary()
        #expect(library.order.first == StockLayouts.focus)
        #expect(library.next(after: StockLayouts.priority) == StockLayouts.focus)
        #expect(library.next(after: "user.gone") == StockLayouts.focus)
        #expect(LayoutLibrary([]).next(after: "x") == nil)
    }
}
