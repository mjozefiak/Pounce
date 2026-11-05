import AppKit
import Foundation
import LintelKit
import SwiftUI
import Synchronization
import Testing

@testable import LintelApp

/// A keychain that counts every call and stores nothing.
nonisolated final class CountingKeychain: KeychainClient {
    private let calls = Mutex(0)

    var callCount: Int { calls.withLock { $0 } }

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        calls.withLock { $0 += 1 }
        throw KeychainError.itemNotFound
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        calls.withLock { $0 += 1 }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        calls.withLock { $0 += 1 }
        throw KeychainError.itemNotFound
    }
}

/// Always enabled: the user cannot switch it off.
final class PinnedPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "pinned", displayName: "Pinned", symbolName: "pin", order: 1, defaultEnabled: false,
        canBeDisabled: false)

    init(context: PluginContext) {}
}

/// Has a Settings pane, to check which host lists it while it is off.
final class PanePlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "pane", displayName: "Pane", symbolName: "gear", order: 2, defaultEnabled: false)

    init(context: PluginContext) {}

    func settingsPane() -> AnyView? { AnyView(Text(verbatim: "Pane")) }
}

/// Spec `2026-11-04-lintel-main-window`, step 1.1: `canBeDisabled`, the panes of inactive plugins and the
/// `settingsPane()` rule.
@Suite struct MainWindowContractShellTests {
    let env: TestEnvironment

    init() throws {
        env = try TestEnvironment()
    }

    @Test func aPluginThatCannotBeDisabledIgnoresAStoredFalse() async {
        defer { env.tearDown() }
        env.settings.setValue(.bool(false), forKey: "plugins.pinned.enabled")
        let host = env.makeHost([PinnedPlugin.self])

        #expect(host.isEnabled("pinned"))
        await host.start()
        #expect(host.state(of: "pinned")?.isActive == true)

        await host.setEnabled(false, for: "pinned")
        #expect(host.state(of: "pinned")?.isActive == true)
        #expect(host.isEnabled("pinned"))
        // The no-op writes nothing: the stored value stays as it was.
        #expect(env.settings.value(forKey: "plugins.pinned.enabled") == .bool(false))
    }

    @Test func onlyTheMainWindowListsThePanesOfInactivePlugins() async {
        defer { env.tearDown() }
        let host = env.makeHost([PanePlugin.self])
        await host.start()

        #expect(host.settingsPanes(includingInactive: false).isEmpty)
        let panes = host.settingsPanes(includingInactive: true)
        #expect(panes.map(\.id) == ["pane"])
        #expect(panes.first?.isActive == false)

        await host.setEnabled(true, for: "pane")
        #expect(host.settingsPanes(includingInactive: false).map(\.id) == ["pane"])
        #expect(host.settingsPanes(includingInactive: true).first?.isActive == true)
    }
}

/// Every registered plugin: its Settings pane can be built and drawn while the plugin is off without touching
/// the Keychain or its `Plugins/<id>/` folder (`BACKWARD_COMPATIBILITY.md` section 1).
@Suite struct InactiveSettingsPaneTests {
    nonisolated static let pluginIDs = ["apps", "files", "clipboard", "dictation", "meetings"]

    @Test func theListCoversEveryRegisteredPlugin() {
        let registered = PluginRegistry.all.map { $0.manifest.id.rawValue }.sorted()
        #expect(registered == Self.pluginIDs.sorted())
    }

    @Test func registeredPluginsUseTheNewDefaultsAndTheirGroups() throws {
        let env = try TestEnvironment()
        defer { env.tearDown() }
        let host = env.makeHost(PluginRegistry.all)
        let groups = Dictionary(uniqueKeysWithValues: host.entries.map { ($0.manifest.id, $0.manifest.settingsGroup) })
        #expect(groups["apps"] == .search)
        #expect(groups["files"] == .search)
        #expect(groups["clipboard"] == .search)
        #expect(groups["dictation"] == .voice)
        #expect(groups["meetings"] == .voice)
        for entry in host.entries {
            let plugin = entry.plugin
            let sections = plugin.workspaceSections.count
            let hasStatus = plugin.settingsStatus != nil
            let kinds = plugin.modelUsage.map(\.kind)
            #expect(entry.manifest.canBeDisabled)
            #expect(sections == 0)
            #expect(!hasStatus)
            // Step 3.2: the voice plugins declare their models; the others none.
            switch entry.manifest.id {
            case "dictation": #expect(kinds == [.speech, .llm])
            case "meetings": #expect(kinds == [.speech, .diarization, .llm])
            default: #expect(kinds.isEmpty)
            }
        }
    }

    @Test(arguments: pluginIDs)
    func paneOfAnInactivePluginTouchesNoStore(_ id: String) async throws {
        let name = "lintel-inactive-pane-\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try AppEnvironment.createPrivateDirectory(root, fileManager: .default)
        defer { try? FileManager.default.removeItem(at: root) }
        let keychain = CountingKeychain()
        let environment = AppEnvironment(
            dataRoot: root,
            cachesRoot: root.appending(path: "Caches", directoryHint: .isDirectory),
            settings: InMemorySettingsStore(),
            keychain: keychain,
            pasteboardName: NSPasteboard.Name(name),
            usage: InMemoryUsageRecorder(),
            registersGlobalHotkeys: false,
            fullDiskAccess: .denied
        )
        let types = PluginRegistry.all.filter { $0.manifest.id.rawValue == id }
        try #require(types.count == 1)
        let host = PluginHost(
            pluginTypes: types,
            makeContext: { environment.makeContext(for: $0) },
            settings: environment.settings
        )
        // Never started: the plugin is inactive, as for a disabled plugin in the main window.
        let panes = host.settingsPanes(includingInactive: true)
        try #require(panes.count == 1)
        #expect(panes[0].isActive == false)

        // In a real (off-screen) window, so `.task` and `.onAppear` run as they do on screen.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: panes[0].view)
        window.orderFrontRegardless()
        defer { window.close() }
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }

        #expect(keychain.callCount == 0)
        let storage = environment.storageDirectory(for: PluginID(rawValue: id))
        #expect(!FileManager.default.fileExists(atPath: storage.path))
    }
}
