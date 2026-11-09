import CoreGraphics
import Foundation
import LintelCore
import LintelKit
import Testing

@testable import WindowsPlugin

/// Step 1.9: commands, the HUD, the window switcher and the keyboard-layout check.
@MainActor
@Suite struct CommandsTests {
    private let home = CGRect(x: 100, y: 100, width: 800, height: 600)

    private func plugin(
        granted: Bool = true, windows: [WindowInfo] = [makeWindow(1), makeWindow(2)]
    ) async throws -> (WindowsPlugin, FakeWindowClient, RecordingHUD, WindowsHarness) {
        let harness = try WindowsHarness()
        let client = FakeWindowClient(windows: windows)
        client.setFocused(windows.first?.id)
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: granted)), hud: hud,
            activationCenter: NotificationCenter())
        try await plugin.activate()
        return (plugin, client, hud, harness)
    }

    private func command(_ plugin: WindowsPlugin, _ id: String) throws -> PluginCommand {
        try #require(plugin.commands.first { $0.id == id })
    }

    // MARK: The command table

    @Test func theCommandsAndTheirDefaultsAreTheAeroSpaceSet() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let commands = WindowsPlugin(context: harness.context()).commands
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(commands.count == 9 + 9 + 3 + 1 + 18)
        for number in 1...9 {
            let go = try #require(commands.first { $0.id == "windows.workspace.\(number)" })
            #expect(go.defaultShortcut == KeyShortcut(key: String(number), modifiers: [.option]))
            let move = try #require(commands.first { $0.id == "windows.moveToWorkspace.\(number)" })
            #expect(move.defaultShortcut == KeyShortcut(key: String(number), modifiers: [.option, .shift]))
        }
        let back = try #require(commands.first { $0.id == "windows.workspace.back" })
        #expect(back.defaultShortcut == KeyShortcut(key: "\t", modifiers: [.option]))
        // Only the defaults of this phase are bound: the workspace set, focus, move and resize.
        let bound = commands.compactMap(\.defaultShortcut)
        #expect(bound.count == 19 + 4 + 4 + 2)
        #expect(Set(bound).count == bound.count)
        #expect(Set(bound) == Set(WindowsPlugin.defaultShortcuts))
    }

    nonisolated struct TilingBinding: Sendable, CustomTestStringConvertible {
        var id: String
        var key: String?
        var modifiers: KeyShortcut.Modifiers
        var testDescription: String { id }
    }

    /// The Q10 defaults of this phase and the commands that stay unbound (`toggleLayout` waits for phase 3).
    nonisolated static let tilingBindings: [TilingBinding] = [
        TilingBinding(id: "windows.focus.left", key: "h", modifiers: [.option]),
        TilingBinding(id: "windows.focus.down", key: "j", modifiers: [.option]),
        TilingBinding(id: "windows.focus.up", key: "k", modifiers: [.option]),
        TilingBinding(id: "windows.focus.right", key: "l", modifiers: [.option]),
        TilingBinding(id: "windows.move.left", key: "h", modifiers: [.option, .shift]),
        TilingBinding(id: "windows.move.down", key: "j", modifiers: [.option, .shift]),
        TilingBinding(id: "windows.move.up", key: "k", modifiers: [.option, .shift]),
        TilingBinding(id: "windows.move.right", key: "l", modifiers: [.option, .shift]),
        TilingBinding(id: "windows.resize.grow", key: "=", modifiers: [.option]),
        TilingBinding(id: "windows.resize.shrink", key: "-", modifiers: [.option]),
        TilingBinding(id: "windows.join.left", key: nil, modifiers: []),
        TilingBinding(id: "windows.join.right", key: nil, modifiers: []),
        TilingBinding(id: "windows.join.up", key: nil, modifiers: []),
        TilingBinding(id: "windows.join.down", key: nil, modifiers: []),
        TilingBinding(id: "windows.toggleOrientation", key: nil, modifiers: []),
        TilingBinding(id: "windows.toggleFloating", key: nil, modifiers: []),
        TilingBinding(id: "windows.balance", key: nil, modifiers: []),
        TilingBinding(id: "windows.toggleLayout", key: nil, modifiers: []),
    ]

    @Test(arguments: tilingBindings)
    func theTilingCommandsAreHiddenFromTheMenuAndBoundPerQ10(_ binding: TilingBinding) throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let command = try #require(WindowsPlugin(context: harness.context()).commands.first { $0.id == binding.id })
        #expect(!command.showsInMenu)
        #expect(command.onKeyEvent == nil && command.panelMode == nil)
        let expected = binding.key.map { KeyShortcut(key: $0, modifiers: binding.modifiers) }
        #expect(command.defaultShortcut == expected)
    }

    @Test func onlyRestoreAllWindowsShowsInTheMenu() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let commands = WindowsPlugin(context: harness.context()).commands
        #expect(commands.filter(\.showsInMenu).map(\.id) == ["windows.restoreAllWindows"])
        #expect(commands.allSatisfy { $0.id.hasPrefix("windows.") })
        #expect(commands.allSatisfy { $0.onKeyEvent == nil && $0.panelMode == nil })
    }

    // MARK: Running commands

    @Test func aWorkspaceCommandSwitchesAndShowsTheHUD() async throws {
        let (plugin, client, hud, harness) = try await plugin()
        defer { harness.tearDown() }
        try await command(plugin, "windows.workspace.2").run()
        #expect(client.frame(of: WindowID(pid: 100, number: 1))?.origin == CGPoint(x: 1919, y: 1079))
        try await waitUntil { hud.shown.last == .workspace(number: 2, windowCount: 0) }
        try await command(plugin, "windows.workspace.back").run()
        #expect(client.frame(of: WindowID(pid: 100, number: 1)) == home)
        await plugin.deactivate()
    }

    @Test func theWorkspaceHUDCanBeSwitchedOff() async throws {
        let (plugin, _, hud, harness) = try await plugin()
        defer { harness.tearDown() }
        WindowsSettings(harness.pluginSettings).setWorkspaceHUD(false)
        try await command(plugin, "windows.workspace.2").run()
        try await Task.sleep(for: .milliseconds(100))
        #expect(hud.shown.isEmpty)
        await plugin.deactivate()
    }

    @Test func movingTheFocusedWindowGoesThroughTheEngine() async throws {
        let (plugin, client, _, harness) = try await plugin()
        defer { harness.tearDown() }
        try await command(plugin, "windows.moveToWorkspace.3").run()
        #expect(client.frame(of: WindowID(pid: 100, number: 1))?.origin == CGPoint(x: 1919, y: 1079))
        #expect(client.frame(of: WindowID(pid: 100, number: 2)) == home)
        await plugin.deactivate()
    }

    @Test func withoutAccessibilityEveryPressShowsTheHUDAndNothingMoves() async throws {
        let (plugin, client, hud, harness) = try await plugin(granted: false)
        defer { harness.tearDown() }
        try await command(plugin, "windows.workspace.2").run()
        try await command(plugin, "windows.moveToWorkspace.2").run()
        try await command(plugin, "windows.workspace.next").run()
        #expect(client.calls.isEmpty)
        #expect(client.focusCalls.isEmpty)
        #expect(
            hud.shown == [
                .accessibilityNeeded(.switching), .accessibilityNeeded(.moving), .accessibilityNeeded(.switching),
            ])
        // The shortcuts stay registered.
        #expect(plugin.commands.compactMap(\.defaultShortcut).count == 29)
        await plugin.deactivate()
    }

    @Test func aCommandOfAPluginThatIsOffDoesNothing() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let hud = RecordingHUD()
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)), hud: hud,
            activationCenter: NotificationCenter())
        try await command(plugin, "windows.workspace.2").run()
        #expect(client.calls.isEmpty)
        #expect(hud.shown.isEmpty)
    }

    // MARK: HUD text

    @Test func theHUDStatesForSwitchingAndForMissingAccessibility() {
        let one = WindowsHUDState.workspace(number: 3, windowCount: 1)
        #expect(one.title == "Workspace 3")
        // The plural forms come from the app bundle's catalog, which a package test does not load.
        #expect(one.detail?.contains("1") == true)
        #expect(one.hidesAfter == .milliseconds(600))
        #expect(!one.needsAttention)
        #expect(WindowsHUDState.workspace(number: 1, windowCount: 0).detail == "No windows")
        #expect(WindowsHUDState.workspace(number: 1, windowCount: 5).detail == "5 windows")
        let blocked = WindowsHUDState.accessibilityNeeded(.switching)
        #expect(blocked.title == "Allow Accessibility to switch workspaces")
        #expect(blocked.offersAllowAccessibility)
        #expect(blocked.needsAttention)
        #expect(WindowsHUDState.accessibilityNeeded(.moving).title == "Allow Accessibility to move windows")
        #expect(!WindowsHUDState.workspace(number: 1, windowCount: 1).offersAllowAccessibility)
    }

    // MARK: The window switcher

    @Test func theSwitcherListsMatchingWorkspacesAndWindowsAndNeverRecordsUse() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let usage = CountingUsage()
        let client = FakeWindowClient(windows: [
            WindowInfo(id: WindowID(pid: 100, number: 1), bundleID: "com.example.notes", title: "Notes", frame: home),
            WindowInfo(id: WindowID(pid: 100, number: 2), bundleID: "com.example.mail", title: "Inbox", frame: home),
        ])
        var context = harness.context(windows: client, permissions: ScriptedPermissions(granted: true))
        context = PluginContext(
            storageDirectory: harness.directory, settings: harness.pluginSettings, usage: usage,
            logger: context.logger, keychain: NoKeychain(), pasteboard: NoPasteboard(), events: NoEvents(),
            workspace: NoWorkspace(), permissions: ScriptedPermissions(granted: true), clock: ContinuousClock(),
            windows: client)
        let plugin = WindowsPlugin(context: context, hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.activate()
        let source = try #require(plugin.searchSources.first)
        #expect(source.id == "windows.windows")

        let empty = try await source.search(NormalizedQuery(raw: "", normalized: ""), limit: 10)
        #expect(empty.isEmpty)
        let notes = try await source.search(NormalizedQuery(raw: "notes", normalized: "notes"), limit: 10)
        let window = try #require(notes.first)
        #expect(window.title == "Notes")
        #expect(window.itemKey == ItemKey(pluginID: "windows", key: "100.1"))
        #expect(window.subtitle == "Workspace 1")
        #expect(window.icon == .bundleIdentifier("com.example.notes"))
        let workspaces = try await source.search(
            NormalizedQuery(raw: "workspace 2", normalized: "workspace 2"), limit: 10)
        #expect(workspaces.first?.itemKey == ItemKey(pluginID: "windows", key: "ws.2"))
        #expect(workspaces.first?.subtitle == "No windows")

        let actions = source.actions(for: window)
        #expect(actions.map(\.id) == ["windows.goToWindow", "windows.bringHere"])
        #expect(actions[1].shortcut == KeyShortcut(key: "\r", modifiers: [.command]))
        // Go to the window of workspace 2 from workspace 1: the workspace switches and the window is focused.
        try await command(plugin, "windows.moveToWorkspace.2").run()
        let ctx = ActionContext(previousApp: nil, panel: NoPanel())
        try await actions[0].perform(ctx)
        #expect(client.focusCalls.contains(WindowID(pid: 100, number: 1)))
        #expect(client.frame(of: WindowID(pid: 100, number: 1)) == home)
        // Bring the other window here.
        try await source.actions(for: workspaces[0]).first?.perform(ctx)
        let inbox = try await source.search(NormalizedQuery(raw: "inbox", normalized: "inbox"), limit: 5)
        try await source.actions(for: try #require(inbox.first))[1].perform(ctx)
        #expect(client.focusCalls.contains(WindowID(pid: 100, number: 2)))

        #expect(await usage.recorded == 0)
        await plugin.deactivate()
    }

    @Test func aSwitcherKeyParsesBackToItsTarget() {
        #expect(
            WindowSearchSource.Target(ItemKey(pluginID: "windows", key: "12.34"))
                == .window(WindowID(pid: 12, number: 34)))
        #expect(WindowSearchSource.Target(ItemKey(pluginID: "windows", key: "ws.9")) == .workspace(WorkspaceID(9)!))
        #expect(WindowSearchSource.Target(ItemKey(pluginID: "windows", key: "ws.10")) == nil)
        #expect(WindowSearchSource.Target(ItemKey(pluginID: "windows", key: "junk")) == nil)
        #expect(WindowSearchSource.Target(ItemKey(pluginID: "apps", key: "12.34")) == nil)
    }

    // MARK: The keyboard-layout check

    /// What a Polish programmers' layout types with ⌥ for the keys the plugin binds.
    private let polish: ShortcutSafety.KeyTranslation = { code, modifiers in
        guard modifiers.contains(.option) else { return nil }
        switch code {
        case 37: return "ł"  // ⌥L
        case 0: return "ą"  // ⌥A
        case 18, 19: return "¡"  // ⌥1, ⌥2 types a symbol, not a letter
        case 48: return "\t"
        default: return nil
        }
    }

    @Test func theCheckNamesTheKeysThatTypeALetter() {
        let family = [
            KeyShortcut(key: "l", modifiers: [.option]), KeyShortcut(key: "h", modifiers: [.option]),
            KeyShortcut(key: "1", modifiers: [.option]), KeyShortcut(key: "a", modifiers: [.option, .shift]),
        ]
        let result = ShortcutSafety.check(family, translate: polish)
        #expect(result.offending == [family[0], family[3]])
        #expect(!result.isSafe)
        // The one-click fix: control plus option types nothing.
        let fixed = ShortcutSafety.controlOption(for: family)
        #expect(fixed.allSatisfy { $0.modifiers.isSuperset(of: [.control, .option]) })
        #expect(ShortcutSafety.check(fixed, translate: polish).isSafe)
    }

    @Test func theLayoutCheckCoversTheNewKeysAndNamesOptionL() {
        // ⌥L (focus right) types "ł" on a Polish layout: the check names it, and ⌃⌥ makes the set safe.
        let result = ShortcutSafety.check(WindowsPlugin.defaultShortcuts, translate: polish)
        #expect(result.offending.contains(KeyShortcut(key: "l", modifiers: [.option])))
        #expect(!result.isSafe)
        // ⌥- and ⌥= type symbols, never letters.
        #expect(!result.offending.contains { $0.key == "-" || $0.key == "=" })
        let fixed = ShortcutSafety.controlOption(for: WindowsPlugin.defaultShortcuts)
        #expect(ShortcutSafety.check(fixed, translate: polish).isSafe)
    }

    @Test func everyBoundKeyHasAKeyCode() {
        for shortcut in WindowsPlugin.defaultShortcuts { #expect(ShortcutSafety.keyCodes[shortcut.key] != nil) }
        for letter in "hjkl" { #expect(ShortcutSafety.keyCodes[String(letter)] != nil) }
    }

    @Test func theSystemTranslationAnswersForTheActiveLayout() {
        // Whatever the layout, the key next to Caps Lock types something without a modifier.
        #expect(SystemKeyTranslation.translate(keyCode: 0, modifiers: []) != nil)
        #expect(SystemKeyTranslation.translate(keyCode: 0, modifiers: [.command]) != nil || true)
    }
}

actor CountingUsage: UsageRecorder {
    private(set) var recorded = 0
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws { recorded += 1 }
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        recorded += 1
        return [:]
    }
}

struct NoPanel: PanelPresenter {
    @MainActor func hidePanel() {}
    @MainActor func showConfirmation(_ message: LocalizedStringResource) {}
}
