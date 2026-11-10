#if DEBUG
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The QA verbs of Window Management (`WindowsPlugin+QA.swift`): resetState, snap, import, export, addFloating run
/// through the same entry points as the UI, with scripted files so no open or save panel ever opens (QA N6, N8).
@Suite(.timeLimit(.minutes(1))) @MainActor struct QACommandVerbsTests {
    private func rig() async throws -> (WindowsPlugin, FakeWindowClient, WindowsHarness) {
        let harness = try WindowsHarness()
        harness.pluginSettings.set(true, for: WindowsSettings.Key.qaScriptedFiles)
        WindowsSettings(harness.pluginSettings).setDefaultKind(.zones)
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        client.setFocused(WindowID(pid: 100, number: 1))
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        try await plugin.activate()
        return (plugin, client, harness)
    }

    @Test func unknownAndIncompleteVerbsAnswerAnError() async throws {
        let (plugin, _, harness) = try await rig()
        defer { harness.tearDown() }
        #expect(await plugin.runQACommand("nonsense").hasPrefix("error"))
        #expect(await plugin.runQACommand("import").hasPrefix("error"))
        #expect(await plugin.runQACommand("snap").hasPrefix("error"))
        #expect(await plugin.runQACommand("").hasPrefix("error"))
        await plugin.deactivate()
    }

    @Test func resetStateAndSnapRunThroughTheRuntime() async throws {
        let (plugin, client, harness) = try await rig()
        defer { harness.tearDown() }
        // Window 1 is focused: snapping it to zone 2 of Columns 2 moves it to the right column.
        #expect(await plugin.runQACommand("snap 2") == "ok")
        await plugin.runtime?.settle()
        #expect(client.frame(of: WindowID(pid: 100, number: 1))?.minX == 964)
        #expect(await plugin.runQACommand("snap 9").hasPrefix("error"))
        // Reset state freezes the engine like a restore, so no zone is offered until the next workspace command.
        #expect(await plugin.runQACommand("resetState") == "ok")
        #expect(await plugin.runQACommand("snap 2").hasPrefix("error"))
        await plugin.deactivate()
    }

    @Test func exportThenImportRoundTripThroughScriptedFilesAndNoPanelOpens() async throws {
        let (plugin, _, harness) = try await rig()
        defer { harness.tearDown() }
        let file = FileManager.default.temporaryDirectory.appending(
            path: "qa-layouts-\(UUID().uuidString).lintellayouts")
        defer { try? FileManager.default.removeItem(at: file) }
        // Make a layout of my own to export, directly through the repository.
        let repository = try #require(plugin.runtime?.layouts)
        _ = try await repository.create(StockLayouts.layout(StockLayouts.columns3)!)
        #expect(await plugin.runQACommand("export \(file.path)").hasPrefix("ok"))
        #expect(FileManager.default.fileExists(atPath: file.path))
        let before = await repository.userLayouts.count
        #expect(await plugin.runQACommand("import \(file.path)").hasPrefix("ok"))
        #expect(await repository.userLayouts.count == before + 1)
        // A missing file is reported, not a panel.
        #expect(await plugin.runQACommand("import /nonexistent/file.lintellayouts").hasPrefix("error"))
        plugin.layoutsWindow.close()
        await plugin.deactivate()
    }

    @Test func addFloatingUsesTheScriptedPickerNotTheOpenPanel() async throws {
        let (plugin, _, harness) = try await rig()
        defer { harness.tearDown() }
        #expect(await plugin.runQACommand("addFloating com.example.qa") == "ok")
        #expect(WindowsSettings(harness.pluginSettings).floatingApps.contains("com.example.qa"))
        await plugin.deactivate()
    }

    /// QA N8: the open and save panels write their sizes into the real defaults domain. They may only be built in the
    /// two places that the scripted files replace in a QA run.
    @Test func thePanelsAreBuiltOnlyWhereTheScriptedFilesReplaceThem() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/WindowsPlugin")
        var users: [String] = []
        for file in FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap({ $0 as? URL }
        )
            ?? []
        where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("NSOpenPanel()") || text.contains("NSSavePanel()") { users.append(file.lastPathComponent) }
        }
        #expect(users.sorted() == ["LayoutsModel+Library.swift", "WindowsSettingsModel.swift"])
    }
}
#endif
