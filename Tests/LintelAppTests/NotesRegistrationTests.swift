import Foundation
import LintelKit
import Testing

@testable import LintelApp

/// Notes is enabled in every build since step 7.1 of the Notes spec (`2026-11-04-notes-workspace`, ADR 0008
/// "Release gate"): the registry has it unconditionally and nothing the feature adds to the shell, Meetings or
/// Dictation is still behind `#if DEBUG` (`ReleaseGateTests` keeps the main window itself in every build). The
/// sources are scanned because the tests run in a DEBUG configuration and cannot tell the two builds apart.
@Suite struct NotesRegistrationTests {
    private static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func debugOnlyText(_ path: String) throws -> String {
        // The scanner of the release gate: the lines a release build does not compile.
        ReleaseGateTests.debugOnlyLines(try String(contentsOf: Self.root.appending(path: path), encoding: .utf8))
            .joined(separator: "\n")
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
    }

    /// `marker` is in `path` and not in a line that a release build leaves out.
    private func expectNoDebugGuard(around marker: String, in path: String) throws {
        #expect(try text(path).contains(marker), "\(path) no longer mentions \(marker)")
        #expect(!(try debugOnlyText(path)).contains(marker), "\(path) has \(marker) inside #if DEBUG again")
    }

    @Test func theRegistryNamesNotesOutsideAnyDebugBlock() throws {
        try expectNoDebugGuard(around: "NotesPlugin.self", in: "Sources/LintelApp/PluginRegistry.swift")
        #expect(!(try text("Sources/LintelApp/PluginRegistry.swift")).contains("#if"))
    }

    @Test func theNotesSentenceOfTheConfirmationSheetsIsNotDebugOnly() throws {
        for path in [
            "Sources/LintelApp/Settings/FeaturesPane.swift",
            "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift",
            "Sources/DictationPlugin/DictationSettingsPane.swift",
        ] {
            try expectNoDebugGuard(around: ".keptNotesCopies", in: path)
        }
    }

    @Test func theDictationOpenInLintelActionIsNotDebugOnly() throws {
        try expectNoDebugGuard(
            around: "dictation.history.openInLintel", in: "Sources/DictationPlugin/DictationHistorySource.swift")
        try expectNoDebugGuard(around: "openInNotes", in: "Sources/DictationPlugin/DictationHistorySource.swift")
        try expectNoDebugGuard(around: "openInNotes", in: "Sources/DictationPlugin/DictationPlugin.swift")
    }

    @Test func everyBuildRegistersNotesThatCannotBeDisabled() throws {
        let notes = try #require(PluginRegistry.all.first { $0.manifest.id == "notes" })
        #expect(!notes.manifest.canBeDisabled)
        #expect(PluginRegistry.all.filter { $0.manifest.id == "notes" }.count == 1)
    }
}

@MainActor
@Suite struct PaletteCommandsTests {
    @Test func theNotesPaletteListsActivePluginCommandsThenOpenSettings() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let coordinator = AppCoordinator(
            environment: test.environment, pluginTypes: [AlphaPlugin.self, BetaPlugin.self],
            registrar: InMemoryHotkeyRegistrar(), occupiedShortcuts: { [] }, launchAtLogin: NoLaunchAtLogin())
        await coordinator.host.start()
        let commands = coordinator.paletteCommands()
        // Beta is off by default, so its command is not offered.
        #expect(commands.map { String(localized: $0.title) } == ["Open Alpha", "Open Settings"])
        #expect(commands.last?.shortcut == KeyShortcut(key: ",", modifiers: [.command]))
        // The context a plugin gets answers with the same list.
        #expect(try #require(coordinator.host.entries.first).plugin is AlphaPlugin)
    }

    @Test func aHotkeyShortcutConvertsToTheContractsKeyShortcut() {
        let record = HotkeyShortcut(carbonKeyCode: 46, carbonModifiers: 4096 | 2048)  // ⌃⌥M
        #expect(record.keyShortcut == KeyShortcut(key: "m", modifiers: [.control, .option]))
        #expect(HotkeyShortcut.commandSpace.keyShortcut == KeyShortcut(key: " ", modifiers: [.command]))
    }
}
