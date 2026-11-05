import Foundation
import LintelKit
import Synchronization
import Testing

@testable import AppsPlugin

@Suite @MainActor struct AppSuggestionSourceTests {
    struct Harness {
        let source: AppSuggestionSource
        let settings: MemorySettings
        let workspace: ScriptedWorkspace
        let activity: ActivityStore
        let usage: RecordingUsage
        let directory: TemporaryDirectory
        let changes: ChangeCounter
    }

    final class ChangeCounter: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    func makeHarness(file: Data? = nil) async throws -> Harness {
        let directory = try TemporaryDirectory()
        if let file {
            try file.write(to: directory.url.appending(path: ActivityStore.fileName))
        }
        let time = VirtualTime()
        let activity = ActivityStore(directory: directory.url, now: time.now, clock: NeverClock())
        await activity.load()
        let store = AppStore()
        store.publish([
            AppRecord(bundleIdentifier: "com.example.mail", path: "/Applications/Mail.app", name: "Mail"),
            AppRecord(bundleIdentifier: "com.example.notes", path: "/Applications/Notes.app", name: "Notes"),
            AppRecord(bundleIdentifier: "com.example.maps", path: "/Applications/Maps.app", name: "Maps"),
        ])
        let settings = MemorySettings()
        let workspace = ScriptedWorkspace(time: time)
        let usage = RecordingUsage()
        let changes = ChangeCounter()
        let source = AppSuggestionSource(
            store: store, activity: activity, settings: PluginSettings(pluginID: "apps", store: settings),
            usage: usage, workspace: workspace, ownBundleIdentifier: "com.lintelapp.Lintel",
            resultsChanged: { changes.increment() }, now: time.now)
        for (bundleID, uses) in [("com.example.mail", 3), ("com.example.notes", 2), ("com.example.maps", 1)] {
            for _ in 0..<uses {
                await activity.recordUse(of: bundleID, at: time.date)
            }
        }
        return Harness(
            source: source, settings: settings, workspace: workspace, activity: activity, usage: usage,
            directory: directory, changes: changes)
    }

    @Test func suggestsAppsWithIconsAndRunningBadges() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        harness.workspace.running = ["com.example.notes"]
        let found = try await harness.source.suggestions(limit: 5)
        #expect(
            found.map(\.itemKey.rawValue) == [
                "apps:com.example.mail", "apps:com.example.notes", "apps:com.example.maps",
            ])
        #expect(found.map(\.badge) == [nil, "Running", nil])
        #expect(found[0].icon == .file(URL(filePath: "/Applications/Mail.app", directoryHint: .isDirectory)))
        #expect(try await harness.source.suggestions(limit: 2).count == 2)
    }

    @Test func actionsOpenRevealAndHide() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        let found = try await harness.source.suggestions(limit: 5)
        let actions = harness.source.actions(for: found[0])
        #expect(actions.map(\.id) == [AppActions.openID, AppActions.revealID, AppSuggestionSource.hideID])
        #expect(actions[2].shortcut == KeyShortcut(key: "x", modifiers: .control))
        #expect(actions[2].keepsPanelOpen)

        let context = ActionContext(previousApp: nil, panel: NoPanel())
        try await actions[0].perform(context)
        #expect(harness.workspace.opened == [URL(filePath: "/Applications/Mail.app", directoryHint: .isDirectory)])
        #expect(await harness.usage.uses.map(\.0.rawValue) == ["apps:com.example.mail"])
        try await actions[1].perform(context)
        #expect(harness.workspace.reveals == [[URL(filePath: "/Applications/Mail.app", directoryHint: .isDirectory)]])

        try await actions[2].perform(context)
        #expect(harness.settings.value(forKey: "plugins.apps.suggestions.hidden") == .stringArray(["com.example.mail"]))
        #expect(harness.changes.value == 1)
        let after = try await harness.source.suggestions(limit: 5)
        #expect(after.map(\.itemKey.key) == ["com.example.notes", "com.example.maps"])
    }

    @Test func turnedOffSuggestsNothing() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        harness.settings.setValue(.bool(false), forKey: "plugins.apps.suggestions.enabled")
        #expect(try await harness.source.suggestions(limit: 5).isEmpty)
    }

    @Test func aCancelledTaskThrowsCancellation() async throws {
        let harness = try await makeHarness()
        defer { harness.directory.remove() }
        let source = harness.source
        let task = Task.detached { try await source.suggestions(limit: 5) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aNewerFileSuggestsNothingWithoutError() async throws {
        let harness = try await makeHarness(file: Data(#"{"version":3}"#.utf8))
        defer { harness.directory.remove() }
        #expect(try await harness.source.suggestions(limit: 5).isEmpty)
    }
}
