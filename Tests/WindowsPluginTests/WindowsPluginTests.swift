import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

@MainActor
@Suite struct WindowsPluginTests {
    @Test func theManifestIsDisabledByDefaultAndNeedsAccessibility() throws {
        let manifest = WindowsPlugin.manifest
        #expect(manifest.id == "windows")
        #expect(manifest.order == 60)
        #expect(manifest.defaultEnabled == false)
        #expect(manifest.canBeDisabled)
        #expect(manifest.settingsGroup == .lintel)
        #expect(manifest.summary != nil)
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(context: harness.context())
        #expect(plugin.requiredPermissions == [.accessibility])
    }

    @Test func activationThrowsWhenTheClientIsUnsupported() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(context: harness.context(windows: UnsupportedClient(reason: "no symbol")))
        await #expect(throws: WindowsPlugin.StartError.unsupported(reason: "no symbol")) {
            try await plugin.activate()
        }
        // The default client of a context is unsupported too.
        let byDefault = WindowsPlugin(context: harness.context())
        await #expect(throws: WindowsPlugin.StartError.self) { try await byDefault.activate() }
    }

    @Test func activationSucceedsWhenTheClientIsAvailable() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let plugin = WindowsPlugin(context: harness.context(windows: AvailableClient()))
        try await plugin.activate()
        await plugin.deactivate()
        await plugin.deactivate()
    }
}

@Suite struct WindowsSettingsTests {
    @Test func defaults() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        #expect(settings.workspaceCount == 4)
        #expect(settings.floatingApps == WindowsSettings.defaultFloatingApps)
        #expect(settings.followFocus)
        #expect(settings.workspaceHUD)
        #expect(settings.stripEnabled)
        #expect(settings.stripMode == .all)
        #expect(!settings.safeMode)
        #expect(settings.parkedLaunches == 0)
    }

    @Test func workspaceCountIsClampedToOneThroughNine() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        harness.store.setValue(.integer(0), forKey: "plugins.windows.workspaceCount")
        #expect(settings.workspaceCount == 1)
        harness.store.setValue(.integer(40), forKey: "plugins.windows.workspaceCount")
        #expect(settings.workspaceCount == 9)
        settings.setWorkspaceCount(12)
        #expect(settings.workspaceCount == 9)
        settings.setWorkspaceCount(6)
        #expect(settings.workspaceCount == 6)
    }

    @Test func settersRoundTripUnderThePluginPrefix() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setFloatingApps(["a.b"])
        settings.setFollowFocus(false)
        settings.setWorkspaceHUD(false)
        settings.setStripEnabled(false)
        settings.setStripMode(.occupied)
        settings.setSafeMode(true)
        settings.setParkedLaunches(2)
        #expect(settings.floatingApps == ["a.b"])
        #expect(!settings.followFocus)
        #expect(!settings.workspaceHUD)
        #expect(!settings.stripEnabled)
        #expect(settings.stripMode == .occupied)
        #expect(settings.safeMode)
        #expect(settings.parkedLaunches == 2)
        #expect(harness.store.keys.allSatisfy { $0.hasPrefix("plugins.windows.") })
    }

    @Test func anUnknownStripModeFallsBackToAll() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        harness.store.setValue(.string("nonsense"), forKey: "plugins.windows.strip.mode")
        #expect(WindowsSettings(harness.pluginSettings).stripMode == .all)
    }

    /// Every key constant is unique, so two settings never share storage.
    @Test func keysAreUnique() {
        let keys = [
            WindowsSettings.Key.workspaceCount, WindowsSettings.Key.floatingApps, WindowsSettings.Key.followFocus,
            WindowsSettings.Key.workspaceHUD, WindowsSettings.Key.stripEnabled, WindowsSettings.Key.stripMode,
            WindowsSettings.Key.safeMode, WindowsSettings.Key.parkedLaunches,
        ]
        #expect(Set(keys).count == keys.count)
    }
}

struct UnsupportedClient: WindowClient {
    let reason: String
    var availability: WindowClientAvailability { .unsupported(reason: reason) }
    func windows() async -> [WindowInfo] { [] }
    func focusedWindow() async -> WindowID? { nil }
    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect { throw .windowGone }
    func focus(_ id: WindowID) async throws(WindowClientError) { throw .windowGone }
    func displays() async -> [DisplayInfo] { [] }
    var events: AsyncStream<WindowEvent> { AsyncStream { $0.finish() } }
}

private struct AvailableClient: WindowClient {
    var availability: WindowClientAvailability { .available }
    func windows() async -> [WindowInfo] { [] }
    func focusedWindow() async -> WindowID? { nil }
    func setFrame(_ frame: CGRect, for id: WindowID) async throws(WindowClientError) -> CGRect { frame }
    func focus(_ id: WindowID) async throws(WindowClientError) {}
    func displays() async -> [DisplayInfo] { [] }
    var events: AsyncStream<WindowEvent> { AsyncStream { $0.finish() } }
}
