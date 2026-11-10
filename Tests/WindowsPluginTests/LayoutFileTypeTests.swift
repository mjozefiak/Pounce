import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// The `.lintellayouts` type (step 4.4): declared in `Info.plist`, and the plugin takes only that file type.
@Suite(.timeLimit(.minutes(1))) struct LayoutFileTypeTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appending(path: "Resources/Info.plist"))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func infoPlistExportsTheTypeAndOffersTheAppAsItsOwner() throws {
        let plist = try plist()
        let exported = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let type = try #require(exported.first { $0["UTTypeIdentifier"] as? String == LayoutFileType.identifier })
        #expect(type["UTTypeConformsTo"] as? [String] == ["public.json"])
        let tags = try #require(type["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == [LayoutFileType.fileExtension])
        let documents = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try #require(
            documents.first { ($0["LSItemContentTypes"] as? [String])?.contains(LayoutFileType.identifier) == true })
        #expect(document["LSHandlerRank"] as? String == "Owner")
        // Additive: the agent app settings are untouched.
        #expect(plist["LSUIElement"] as? Bool == true)
        #expect(LayoutFileType.identifier == "com.lintelapp.layouts")
        #expect(LayoutFileType.fileExtension == "lintellayouts")
    }

    @MainActor @Test func aFileOfAnotherTypeIsLeftAlone() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(
            context: harness.context(), hud: RecordingHUD(), activationCenter: NotificationCenter())
        #expect(await plugin.handleOpenedFile(URL(fileURLWithPath: "/tmp/notes.json")) == false)
        #expect(await plugin.handleOpenedFile(URL(fileURLWithPath: "/tmp/layouts.txt")) == false)
        #expect(!plugin.layoutsWindow.isOpen)
    }

    @MainActor @Test func aLayoutsFileOpensTheWindowAndShowsTheSummaryWithoutAddingAnything() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        plugin.layoutsWindow.activatesApp = false
        try await plugin.activate()
        let url = harness.directory.appending(path: "shared.LintelLayouts")
        let text =
            #"{"version":1,"layouts":[{"id":"user.x","name":"Shared","style":"grid","spacing":4,"grid":{"columns":[1],"rows":[1],"zones":[{"id":1,"colStart":0,"colEnd":1,"rowStart":0,"rowEnd":1}]}}]}"#
        try Data(text.utf8).write(to: url)
        #expect(await plugin.handleOpenedFile(url))
        let model = try #require(plugin.layoutsWindow.model)
        #expect(model.pendingImport?.layouts.map(\.name) == ["Shared"])
        #expect(await plugin.runtime?.layouts.userLayouts.isEmpty == true)
        await model.confirmImport()
        #expect(model.userLayouts.map(\.name) == ["Shared"])
        plugin.layoutsWindow.close()
        await plugin.deactivate()
    }

    @MainActor @Test func aLayoutsFileWhileThePluginIsOffOnlySaysSo() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(
            context: harness.context(), hud: RecordingHUD(), activationCenter: NotificationCenter())
        plugin.layoutsWindow.activatesApp = false
        let url = harness.directory.appending(path: "shared.lintellayouts")
        try Data(#"{"version":1,"layouts":[]}"#.utf8).write(to: url)
        #expect(await plugin.handleOpenedFile(url))
        let model = try #require(plugin.layoutsWindow.model)
        #expect(model.pendingImport == nil)
        #expect(model.notice != nil)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: "layouts.json").path))
        plugin.layoutsWindow.close()
    }

    @MainActor @Test func discardingAfterThePluginWasSwitchedOffClosesTheLayoutsWindowToo() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let client = FakeWindowClient(windows: [makeWindow(1)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: true)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        plugin.layoutsWindow.activatesApp = false
        plugin.editorWindow.activatesApp = false
        try await plugin.activate()
        plugin.layoutsWindow.show()
        plugin.openEditor(layout: LayoutsModel.newDraft(), isNew: true, parent: plugin.layoutsWindow.window)
        let editor = try #require(plugin.editorWindow.model)
        editor.divide(zone: 1, axis: .vertical)
        await plugin.deactivate()
        // The editor has changes, so both windows wait for the answer.
        #expect(plugin.editorWindow.isOpen && plugin.layoutsWindow.isOpen)
        editor.discard()
        #expect(!plugin.editorWindow.isOpen)
        #expect(!plugin.layoutsWindow.isOpen)
    }
}
