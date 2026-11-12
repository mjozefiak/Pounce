import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// Window management v2, Phase 1: the migration of the default shortcuts, the layout commands, the resize step and
/// the new defaults.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct V2CommandsTests {
    private func opt(_ key: String) -> KeyShortcut { KeyShortcut(key: key, modifiers: [.option]) }
    private func optShift(_ key: String) -> KeyShortcut { KeyShortcut(key: key, modifiers: [.option, .shift]) }

    /// A shortcut table the migration reads and writes, like the host's registrar.
    private final class Table {
        var shortcuts: [String: KeyShortcut] = [:]
    }

    private func migrate(_ table: Table, from version: Int = 0) -> Int {
        ShortcutMigration(
            commandIDs: WindowsCommandID.shortcutCommandIDs(in: .standard),
            shortcut: { table.shortcuts[$0] },
            setShortcut: { table.shortcuts[$0] = $1 }
        ).run(from: version)
    }

    /// What a user who switched the plugin on in v1 has stored.
    private func v1Defaults() -> Table {
        let table = Table()
        for (direction, key) in [(LayoutDirection.left, "h"), (.down, "j"), (.up, "k"), (.right, "l")] {
            table.shortcuts[WindowsCommandID.focus(direction)] = opt(key)
            table.shortcuts[WindowsCommandID.move(direction)] = optShift(key)
        }
        table.shortcuts[WindowsCommandID.toggleLayout] = opt("/")
        table.shortcuts[WindowsCommandID.grow] = opt("=")
        return table
    }

    // MARK: The migration of the default shortcuts

    @Test func theV1DefaultsMoveToTheAeroSpaceSetWithOneOwnerPerKey() {
        let table = v1Defaults()
        #expect(migrate(table) == 1)
        let s = table.shortcuts
        #expect(s[WindowsCommandID.focus(.left)] == opt("j") && s[WindowsCommandID.focus(.right)] == opt("k"))
        #expect(s[WindowsCommandID.move(.left)] == optShift("j") && s[WindowsCommandID.move(.right)] == optShift("k"))
        // ⌥K moved from "focus up" to "focus right": up and down have none now.
        #expect(s[WindowsCommandID.focus(.up)] == nil && s[WindowsCommandID.focus(.down)] == nil)
        #expect(s[WindowsCommandID.move(.up)] == nil && s[WindowsCommandID.move(.down)] == nil)
        // ⌥/ is freed for `layout.tiles`; the commands that did not change are left alone.
        #expect(s[WindowsCommandID.toggleLayout] == nil)
        #expect(s[WindowsCommandID.grow] == opt("="))
        let owners = s.values.map { "\($0.key)\($0.modifiers.rawValue)" }
        #expect(Set(owners).count == owners.count)
    }

    @Test func aShortcutTheUserChangedIsNeverTouched() {
        let table = v1Defaults()
        table.shortcuts[WindowsCommandID.focus(.left)] = KeyShortcut(key: "h", modifiers: [.control, .option])
        table.shortcuts[WindowsCommandID.toggleLayout] = opt("m")
        _ = migrate(table)
        #expect(
            table.shortcuts[WindowsCommandID.focus(.left)] == KeyShortcut(key: "h", modifiers: [.control, .option]))
        #expect(table.shortcuts[WindowsCommandID.toggleLayout] == opt("m"))
        // The ones that were still the default did move.
        #expect(table.shortcuts[WindowsCommandID.focus(.right)] == opt("k"))
    }

    @Test func aCommandWithNoStoredShortcutStaysWithoutOne() {
        let table = Table()
        #expect(migrate(table) == 1)
        #expect(table.shortcuts.isEmpty)
    }

    @Test func aKeyAnotherCommandHoldsIsNotTakenSilently() {
        let table = v1Defaults()
        // The user bound ⌥K to a numbered command: `focus.right` keeps its old shortcut free of a second owner.
        table.shortcuts[WindowsCommandID.focus(.up)] = nil
        table.shortcuts[WindowsCommandID.workspace(5)] = opt("k")
        _ = migrate(table)
        #expect(table.shortcuts[WindowsCommandID.workspace(5)] == opt("k"))
        #expect(table.shortcuts[WindowsCommandID.focus(.right)] == nil)
    }

    @Test func theSecondRunChangesNothing() {
        let table = v1Defaults()
        let version = migrate(table)
        let after = table.shortcuts
        #expect(migrate(table, from: version) == version)
        #expect(table.shortcuts == after)
        // Even when the table were back to v1, a run marked as done is skipped.
        let old = v1Defaults()
        #expect(migrate(old, from: 1) == 1)
        #expect(old.shortcuts == v1Defaults().shortcuts)
    }

    @Test func runningAfterSyncCommandsGaveTheNewDefaultsLeavesOneOwnerOfEachKey() {
        // `syncCommands` ran first: the new commands got their defaults while `toggleLayout` still had ⌥/.
        let table = v1Defaults()
        table.shortcuts[WindowsCommandID.layoutTiles] = opt("/")
        table.shortcuts[WindowsCommandID.layoutAccordion] = opt(",")
        _ = migrate(table)
        #expect(table.shortcuts[WindowsCommandID.layoutTiles] == opt("/"))
        #expect(table.shortcuts[WindowsCommandID.toggleLayout] == nil)
        let owners = table.shortcuts.values.map { "\($0.key)\($0.modifiers.rawValue)" }
        #expect(Set(owners).count == owners.count)
    }

    @Test func activatingThePluginRunsTheMigrationOnceAndMarksIt() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let table = v1Defaults()
        let context = PluginContext(
            storageDirectory: harness.directory, settings: harness.pluginSettings, usage: NoUsage(),
            logger: harness.context().logger, keychain: NoKeychain(), pasteboard: NoPasteboard(), events: NoEvents(),
            workspace: NoWorkspace(), permissions: ScriptedPermissions(granted: true), clock: harness.clock,
            windows: FakeWindowClient(windows: [makeWindow(1)]),
            setCommandShortcut: { table.shortcuts[$0] = $1 }, commandShortcut: { table.shortcuts[$0] },
            services: harness.services)
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        #expect(WindowsSettings(harness.pluginSettings).shortcutDefaultsVersion == 0)
        try await plugin.activate()
        #expect(WindowsSettings(harness.pluginSettings).shortcutDefaultsVersion == 1)
        #expect(table.shortcuts[WindowsCommandID.focus(.right)] == opt("k"))
        // A shortcut the user records afterwards survives the next activation.
        table.shortcuts[WindowsCommandID.focus(.right)] = opt("l")
        await plugin.deactivate()
        try await plugin.activate()
        #expect(table.shortcuts[WindowsCommandID.focus(.right)] == opt("l"))
        await plugin.deactivate()
    }

    // MARK: The defaults

    @Test func theNewDefaultsAreTheOwnersAeroSpaceValues() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        #expect(settings.workspaceCount == 9)
        let tiling = TilingStrategy()
        #expect(settings.globalValue(of: tiling.options[0]) == .int(10))
        #expect(settings.globalValue(of: tiling.options[1]) == .int(10))
        let accordion = AccordionStrategy()
        #expect(settings.globalValue(of: accordion.options[0]) == .int(30))
        let step = try #require(tiling.options.first { $0.id == TilingStrategy.resizeStepID })
        #expect(settings.globalValue(of: step) == .int(50))
        #expect(WindowsSettings.Key.accordionPadding == "accordion.padding")
        #expect(WindowsSettings.Key.resizeStep == "resize.step")
        // A stored value wins over the new default.
        settings.setWorkspaceCount(4)
        #expect(settings.workspaceCount == 4)
        // A strip with nine boxes still fits (`StripModel` limits the width, not the count).
        #expect(
            StripModel.boxes(
                summary: WorkspaceSummary(visible: [:], counts: [:]), workspaceCount: 9, occupiedOnly: false
            ).count == 9)
    }

    @Test func everyDefaultShortcutIsRegistrableAndKnownToTheSafetyCheck() throws {
        for shortcut in WindowsPlugin.defaultShortcuts {
            #expect(ShortcutSafety.keyCodes[shortcut.key] != nil, "\(shortcut.key)")
        }
        #expect(Set(WindowsPlugin.defaultShortcuts).count == WindowsPlugin.defaultShortcuts.count)
        #expect(ShortcutSafety.keyCodes[","] == 43)
    }

    @Test func theCatalogueOfShortcutCommandsCoversTheNewCommands() {
        let ids = WindowsCommandID.shortcutCommandIDs(in: .standard)
        for id in [
            WindowsCommandID.layoutTiles, WindowsCommandID.layoutAccordion, WindowsCommandID.moveToNextDisplay,
            WindowsCommandID.focus(.up), WindowsCommandID.toggleLayout, WindowsCommandID.back, WindowsCommandID.grow,
        ] {
            #expect(ids.contains(id), "\(id)")
        }
        #expect(Set(ids).count == ids.count)
        for id in [WindowsCommandID.layoutTiles, WindowsCommandID.layoutAccordion, WindowsCommandID.moveToNextDisplay] {
            #expect(WindowsCommandID.reserved.contains(id))
        }
    }

    // MARK: Layout commands through the plugin

    private func plugin(windows: Int = 3) async throws -> (WindowsPlugin, FakeWindowClient, WindowsHarness) {
        let harness = try WindowsHarness()
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setDefaultKind(.tiling)
        settings.setInnerGap(0)
        settings.setOuterGap(0)
        let client = FakeWindowClient(windows: (1...windows).map { makeWindow(UInt32($0)) })
        client.setFocused(WindowID(pid: 100, number: 1))
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.activate()
        return (plugin, client, harness)
    }

    private func run(_ plugin: WindowsPlugin, _ id: String) async throws {
        let command = try #require(plugin.commands.first { $0.id == id })
        try await command.run()
        await plugin.runtime?.settle()
    }

    private func overrides(_ harness: WindowsHarness) -> WorkspaceOverride? {
        WindowsSettings(harness.pluginSettings).workspaceOverrides.byWorkspace[WorkspaceID(1)!]
    }

    @Test func accordionLayoutWritesTheKindAndPressedAgainFlipsTheDirection() async throws {
        let (plugin, client, harness) = try await plugin()
        defer { harness.tearDown() }
        try await run(plugin, WindowsCommandID.layoutAccordion)
        #expect(overrides(harness)?.kind == .accordion)
        // Landscape, Auto: horizontal; the three windows share the display's width less the padding.
        let first = try #require(client.frame(of: WindowID(pid: 100, number: 1)))
        let second = try #require(client.frame(of: WindowID(pid: 100, number: 2)))
        #expect(first.width == second.width && first.width < 1920 && first.width > 1800)
        #expect(first.height == second.height)
        // Again: the direction flips to vertical and the kind stays.
        try await run(plugin, WindowsCommandID.layoutAccordion)
        #expect(overrides(harness)?.kind == .accordion)
        #expect(overrides(harness)?.options[AccordionStrategy.orientationID] == .string("vertical"))
        let vertical = try #require(client.frame(of: WindowID(pid: 100, number: 1)))
        #expect(vertical.width == 1920 && vertical.height < 1080)
        // And back to horizontal: the option equals nothing stored but the explicit choice.
        try await run(plugin, WindowsCommandID.layoutAccordion)
        #expect(overrides(harness)?.options[AccordionStrategy.orientationID] == .string("horizontal"))
        await plugin.deactivate()
    }

    @Test func autoTileLayoutFromAccordionClearsTheOverrideAndPressedAgainTogglesTheSplit() async throws {
        let (plugin, client, harness) = try await plugin()
        defer { harness.tearDown() }
        try await run(plugin, WindowsCommandID.layoutAccordion)
        try await run(plugin, WindowsCommandID.layoutTiles)
        // Auto-tile is the default kind: no kind override is left, and the windows tile side by side again.
        #expect(overrides(harness)?.kind == nil)
        #expect(client.frame(of: WindowID(pid: 100, number: 2))?.minX == 640)
        try await run(plugin, WindowsCommandID.layoutTiles)
        // The tree's own split flipped: the three windows stack.
        let state = try #require(await plugin.runtime?.engine.snapshot)
        #expect(state.tiling[WorkspaceID(1)!]?.rootOrientation == .vertical)
        await plugin.deactivate()
    }

    @Test func layoutCommandsNeverOverwriteOverridesFromANewerVersion() async throws {
        let (plugin, _, harness) = try await plugin()
        defer { harness.tearDown() }
        let newer = #"{"version":9,"workspaces":{}}"#
        harness.pluginSettings.set(newer, for: WindowsSettings.Key.workspaces)
        try await run(plugin, WindowsCommandID.layoutAccordion)
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces) == newer)
        await plugin.deactivate()
    }

    @Test func accordionStateIsKeptWhenTheKindChangesAndComesBack() async throws {
        let (plugin, _, harness) = try await plugin()
        defer { harness.tearDown() }
        try await run(plugin, WindowsCommandID.layoutAccordion)
        let engine = try #require(plugin.runtime?.engine)
        let order = try #require((await engine.snapshot).layouts[WorkspaceID(1)!]?["accordion"])
        try await run(plugin, WindowsCommandID.layoutTiles)
        #expect((await engine.snapshot).layouts[WorkspaceID(1)!]?["accordion"] == order)
        try await run(plugin, WindowsCommandID.layoutAccordion)
        #expect((await engine.snapshot).layouts[WorkspaceID(1)!]?["accordion"] == order)
        await plugin.deactivate()
    }

    // MARK: The resize step

    @Test func growAndShrinkMoveAnEdgeByTheResizeStepInPoints() async throws {
        let (plugin, client, harness) = try await plugin()
        defer { harness.tearDown() }
        let id1 = WindowID(pid: 100, number: 1)
        let before = try #require(client.frame(of: id1)).width
        try await run(plugin, WindowsCommandID.grow)
        let grown = try #require(client.frame(of: id1)).width
        // 50 points of the row's 1920, give or take the rounding to whole points.
        #expect(abs((grown - before) - 50) <= 1, "\(grown - before)")
        try await run(plugin, WindowsCommandID.shrink)
        #expect(abs((try #require(client.frame(of: id1)).width) - before) <= 1)
        // The step is a setting.
        harness.pluginSettings.set(100, for: WindowsSettings.Key.resizeStep)
        await plugin.runtime?.applySettings()
        try await run(plugin, WindowsCommandID.grow)
        let bigger = try #require(client.frame(of: id1)).width
        #expect(abs((bigger - before) - 100) <= 1, "\(bigger - before)")
        await plugin.deactivate()
    }

    // MARK: HUD

    @Test func theSingleDisplayNoticeHasAHUDStateThatShowsEvenWithTheHUDOff() {
        let state = WindowsHUDState.singleDisplay
        #expect(state.title == "Only one display" && state.detail == nil)
        #expect(!state.offersAllowAccessibility)
    }
}
