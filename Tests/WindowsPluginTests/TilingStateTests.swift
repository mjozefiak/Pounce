import CoreGraphics
import Foundation
import LintelKit
import Testing

@testable import WindowsPlugin

/// What step 2.4 stores and reads: `workspaces[n].tiling` in `state.json`, the per-workspace overrides value and
/// the settings behind them, and the Accessibility gate through the plugin.
@Suite struct TilingStateTests {
    private func ws(_ number: Int) -> WorkspaceID { WorkspaceID(number)! }

    // MARK: state.json

    @Test func aTreeSurvivesTheFileRoundTrip() throws {
        let shaped = tree(
            .horizontal, [leaf(1, 3), box(.vertical, 2, [leaf(2), box(.horizontal, [leaf(3), leaf(4)])])])
        let state = WindowsState(
            order: [ws(2): [win(1), win(2), win(3), win(4)]], hidden: [], tiling: [ws(2): shaped])
        let data = try JSONEncoder().encode(StateFile(state: state))
        guard case .current(let file) = StateStore.decode(data) else {
            Issue.record("not current")
            return
        }
        #expect(file.state.tiling == [ws(2): shaped])
        #expect(file.state.order == state.order)
    }

    @Test func theFileStaysVersionOne() throws {
        let file = StateFile(state: WindowsState(tiling: [ws(1): tree(.horizontal, [leaf(1), leaf(2)])]))
        #expect(file.version == 1)
        let text = String(decoding: try JSONEncoder().encode(file), as: UTF8.self)
        #expect(text.contains("\"tiling\""))
        #expect(!text.contains("title"))
    }

    @Test func aFileWithoutTilingStillReads() {
        let json = #"{"version":1,"workspaces":{"1":{"order":[{"pid":100,"number":1}]}},"hidden":[]}"#
        guard case .current(let file) = StateStore.decode(Data(json.utf8)) else {
            Issue.record("not current")
            return
        }
        #expect(file.state.order[ws(1)]?.count == 1)
        #expect(file.state.tiling.isEmpty)
    }

    @Test func aTreeThatDoesNotDecodeIsDroppedNotTheFile() {
        let json = """
            {"version":1,"workspaces":{"1":{"order":[{"pid":100,"number":1}],
            "tiling":{"orientation":"sideways"}}},"hidden":[]}
            """
        guard case .current(let file) = StateStore.decode(Data(json.utf8)) else {
            Issue.record("the file was called corrupt")
            return
        }
        #expect(file.state.order[ws(1)]?.count == 1)
        #expect(file.state.tiling.isEmpty)
    }

    @Test func aTreeNestedTooDeeplyIsNotTrusted() {
        var record = TilingRecord(tree(.horizontal, [leaf(1), leaf(2)]))
        for depth in 0..<(TilingRecord.maximumDepth + 2) {
            let orientation: TilingOrientation = depth.isMultiple(of: 2) ? .vertical : .horizontal
            record = TilingRecord(
                orientation: orientation,
                children: [
                    TilingRecord.Child(weight: 1, window: nil, container: record),
                    TilingRecord.Child(weight: 1, window: win(UInt32(depth + 10)), container: nil),
                ])
        }
        #expect(record.tree == nil)
    }

    @Test func aChildWithNeitherWindowNorContainerIsRejected() {
        let record = TilingRecord(
            orientation: .horizontal, children: [TilingRecord.Child(weight: 1, window: nil, container: nil)])
        #expect(record.tree == nil)
    }

    @Test func aFileFromANewerVersionKeepsItsTreesUntouched() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let url = harness.directory.appending(path: StateStore.fileName)
        let json = """
            {"version":2,"workspaces":{"1":{"order":[],"tiling":{"orientation":"horizontal","children":[]}}},
            "hidden":[]}
            """
        try Data(json.utf8).write(to: url)
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        await store.load()
        await store.setTiling([ws(1): tree(.horizontal, [leaf(1), leaf(2)])])
        await store.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == json)
    }

    @Test func theStoreWritesTilingDeferredAndDropsItOnReset() async throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let store = StateStore(directory: harness.directory, saveDelay: .seconds(3600))
        await store.load()
        await store.setTiling([ws(1): tree(.horizontal, [leaf(1), leaf(2)])])
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        await store.flush()
        let again = StateStore(directory: harness.directory)
        await again.load()
        #expect(await again.state.tiling[ws(1)]?.windows.count == 2)
        try await store.reset()
        let empty = StateStore(directory: harness.directory)
        await empty.load()
        #expect(await empty.state.tiling.isEmpty)
    }

    // MARK: Overrides and their resolution

    @Test func unsetOverridesFallBackToTheGlobalDefaults() {
        let config = LayoutConfig(
            defaultKind: .tiling, innerGap: 6, outerGap: 12, rootOrientation: .vertical,
            overrides: [ws(3): WorkspaceOverride(kind: .free, innerGap: 0)])
        let plain = config.resolved(for: ws(1))
        #expect(
            plain
                == ResolvedLayout(kind: .tiling, gaps: TilingGaps(inner: 6, outer: 12), rootOrientation: .vertical))
        let overridden = config.resolved(for: ws(3))
        #expect(overridden.kind == .free)
        #expect(overridden.gaps == TilingGaps(inner: 0, outer: 12))
        #expect(overridden.rootOrientation == .vertical)
    }

    @Test func overridesRoundTripThroughTheirJSONValue() {
        let overrides = WorkspaceOverrides([
            ws(2): WorkspaceOverride(kind: .zones, innerGap: 4, outerGap: 0, rootOrientation: .vertical),
            ws(5): WorkspaceOverride(kind: .free),
        ])
        let again = WorkspaceOverrides(json: overrides.json)
        #expect(again == overrides)
        #expect(overrides.json.contains("\"version\":1"))
    }

    @Test func emptyOverridesStoreNothing() {
        #expect(WorkspaceOverrides([ws(1): WorkspaceOverride()]).json.isEmpty)
        #expect(WorkspaceOverrides(json: nil).byWorkspace.isEmpty)
        #expect(WorkspaceOverrides(json: "").byWorkspace.isEmpty)
    }

    @Test func aNewerOrBrokenValueReadsAsNoOverridesAndIsNeverOverwritten() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        let newer = #"{"version":2,"workspaces":{"1":{"kind":"free"}}}"#
        harness.pluginSettings.set(newer, for: WindowsSettings.Key.workspaces)
        #expect(settings.workspaceOverrides.byWorkspace.isEmpty)
        #expect(settings.workspaceOverrides.isReadOnly)
        #expect(!settings.setWorkspaceOverrides(WorkspaceOverrides([ws(1): WorkspaceOverride(kind: .tiling)])))
        #expect(harness.pluginSettings.string(WindowsSettings.Key.workspaces) == newer)

        harness.pluginSettings.set("not json", for: WindowsSettings.Key.workspaces)
        #expect(settings.workspaceOverrides.isReadOnly)
    }

    @Test func unknownValuesInsideAnOverrideAreIgnoredAndGapsAreClamped() {
        let json = """
            {"version":1,"workspaces":{"1":{"kind":"accordion","innerGap":500,"outerGap":-3,
            "rootOrientation":"diagonal"},"12":{"kind":"free"}}}
            """
        let overrides = WorkspaceOverrides(json: json)
        #expect(overrides.byWorkspace[ws(1)] == WorkspaceOverride(innerGap: WindowsSettings.maximumGap, outerGap: 0))
        #expect(overrides.byWorkspace.count == 1)
    }

    @Test func theLayoutSettingsHaveTheSpecDefaultsAndRoundTrip() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let fresh = WindowsSettings(WindowsHarness.freshSettings())
        #expect(fresh.defaultKind == .tiling)
        #expect(fresh.innerGap == 8 && fresh.outerGap == 8)
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setDefaultKind(.zones)
        settings.setInnerGap(500)
        settings.setOuterGap(-1)
        #expect(settings.defaultKind == .zones)
        #expect(settings.innerGap == WindowsSettings.maximumGap)
        #expect(settings.outerGap == 0)
        harness.pluginSettings.set("bogus", for: WindowsSettings.Key.defaultKind)
        #expect(settings.defaultKind == .tiling)
    }

    @MainActor @Test func theRuntimeConfigCarriesTheSettings() throws {
        let harness = try WindowsHarness()
        defer { harness.tearDown() }
        let settings = WindowsSettings(harness.pluginSettings)
        settings.setDefaultKind(.tiling)
        settings.setInnerGap(3)
        settings.setWorkspaceOverrides(WorkspaceOverrides([ws(2): WorkspaceOverride(kind: .free)]))
        let config = WindowsRuntime.config(settings)
        #expect(config.layout.defaultKind == .tiling)
        #expect(config.layout.innerGap == 3)
        #expect(config.layout.resolved(for: ws(2)).kind == .free)
    }

    // MARK: Through the plugin

    @MainActor
    private func plugin(granted: Bool) async throws -> (WindowsPlugin, FakeWindowClient, WindowsHarness) {
        let harness = try WindowsHarness()
        WindowsSettings(harness.pluginSettings).setDefaultKind(.tiling)
        WindowsSettings(harness.pluginSettings).setInnerGap(0)
        WindowsSettings(harness.pluginSettings).setOuterGap(0)
        let client = FakeWindowClient(windows: [makeWindow(1), makeWindow(2)])
        let plugin = WindowsPlugin(
            context: harness.context(windows: client, permissions: ScriptedPermissions(granted: granted)),
            hud: RecordingHUD(), activationCenter: NotificationCenter())
        return (plugin, client, harness)
    }

    @MainActor @Test func aPluginThatIsNotActiveArrangesNothing() async throws {
        let (plugin, client, harness) = try await plugin(granted: true)
        defer { harness.tearDown() }
        _ = plugin
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.calls.isEmpty)
    }

    @MainActor @Test func anActivePluginWithoutAccessibilityArrangesNothing() async throws {
        let (plugin, client, harness) = try await plugin(granted: false)
        defer { harness.tearDown() }
        try await plugin.activate()
        try await Task.sleep(for: .milliseconds(100))
        #expect(client.calls.isEmpty)
        #expect(client.frame(of: WindowID(pid: 100, number: 1)) == CGRect(x: 100, y: 100, width: 800, height: 600))
        await plugin.deactivate()
    }

    @MainActor @Test func anActivePluginWithAccessibilityTilesTheWindows() async throws {
        let (plugin, client, harness) = try await plugin(granted: true)
        defer { harness.tearDown() }
        try await plugin.activate()
        #expect(client.frame(of: WindowID(pid: 100, number: 1)) == CGRect(x: 0, y: 25, width: 960, height: 1055))
        #expect(client.frame(of: WindowID(pid: 100, number: 2)) == CGRect(x: 960, y: 25, width: 960, height: 1055))
        await plugin.deactivate()
    }
}
