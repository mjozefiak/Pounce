import Foundation
import PounceKit
import Testing

@testable import PounceApp

/// The registry and the default global shortcuts of every registered plugin (a protected contract, see
/// BACKWARD_COMPATIBILITY.md §5): two defaults must never collide, and the shell's own must stay free.
@MainActor
@Suite struct DefaultShortcutTests {
    private func registeredCommands() throws -> [(plugin: PluginID, command: PluginCommand)] {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = env.makeHost(PluginRegistry.all)
        return host.entries.flatMap { entry in entry.plugin.commands.map { (entry.manifest.id, $0) } }
    }

    @Test func theRegistryContainsMeetingsOnce() {
        let ids = PluginRegistry.all.map { $0.manifest.id }
        #expect(ids.filter { $0 == "meetings" }.count == 1)
        #expect(ids == ["apps", "files", "clipboard", "dictation", "meetings"])
    }

    @Test func meetingsIsOffUntilTheUserTurnsItOn() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = env.makeHost(PluginRegistry.all)
        #expect(host.isEnabled("meetings") == false)
        // The plugin has the command, but a disabled plugin registers none, so ⌃⌥M stays free for other apps.
        #expect(try registeredCommands().contains { $0.command.id == "meetings.record" })
        #expect(!host.activeCommands.contains { $0.id == "meetings.record" })
    }

    @Test func everyDefaultShortcutIsUnique() throws {
        var owners: [HotkeyShortcut: String] = [
            .commandSpace: "shell main (preferred)",
            .controlOptionSpace: "shell main (fallback)",
        ]
        let defaults = try registeredCommands().compactMap { entry -> (String, HotkeyShortcut)? in
            guard let shortcut = entry.command.defaultShortcut else { return nil }
            let mapped = HotkeyShortcut(shortcut)
            #expect(mapped != nil, "\(entry.command.id) uses a key Pounce cannot map")
            return mapped.map { (entry.command.id, $0) }
        }
        #expect(!defaults.isEmpty)
        for (id, shortcut) in defaults {
            let previous = owners.updateValue(id, forKey: shortcut)
            #expect(previous == nil, "\(id) collides with \(previous ?? "?") on \(shortcut.displayString)")
        }
    }

    @Test func theKnownDefaultsAreStable() throws {
        let commands = try registeredCommands()
        func shortcut(of id: String) -> String? {
            commands.first { $0.command.id == id }?.command.defaultShortcut
                .flatMap(HotkeyShortcut.init)?.displayString
        }
        #expect(shortcut(of: "dictation.record") == "⌃⌥D")
        #expect(shortcut(of: "clipboard.history") == "⇧⌘V")
        #expect(shortcut(of: "meetings.record") == "⌃⌥M")
    }

    @Test func theRecordCommandAppearsInTheMenuAndHasNoLibraryCommandYet() throws {
        let commands = try registeredCommands().filter { $0.plugin == "meetings" }.map(\.command)
        let record = try #require(commands.first { $0.id == "meetings.record" })
        #expect(record.showsInMenu)
        #expect(record.panelMode == nil)
        // `meetings.library` arrives with the list mode (step 1.11).
        #expect(!commands.contains { $0.id == "meetings.library" })
    }
}
