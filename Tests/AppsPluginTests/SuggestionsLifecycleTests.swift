import Foundation
import PounceKit
import Synchronization
import Testing
import os

@testable import AppsPlugin

@Suite @MainActor struct SuggestionsLifecycleTests {
    struct Harness {
        let plugin: AppsPlugin
        let workspace: ScriptedWorkspace
        let settings: MemorySettings
        let fixture: AppFixture
        let time: VirtualTime
    }

    func makeHarness(_ configure: (MemorySettings) -> Void = { _ in }) throws -> Harness {
        let fixture = try AppFixture()
        try fixture.makeApp("Apps/Notes.app", identifier: "com.example.notes", name: "Notes")
        try fixture.makeApp("Apps/Mail.app", identifier: "com.example.mail", name: "Mail")
        let settings = MemorySettings()
        settings.setValue(.string(fixture.url("Apps").path), forKey: "plugins.apps.roots")
        settings.setValue(.bool(false), forKey: "plugins.apps.spotlight")
        configure(settings)
        let time = VirtualTime()
        let workspace = ScriptedWorkspace(time: time)
        let context = PluginContext(
            storageDirectory: fixture.url("Storage"),
            settings: PluginSettings(pluginID: "apps", store: settings),
            usage: RecordingUsage(),
            logger: Logger(subsystem: "app.pounce.tests", category: "apps"),
            keychain: NoKeychain(),
            pasteboard: NoPasteboard(),
            events: NoEvents(),
            workspace: workspace,
            permissions: NoPermissions(),
            clock: VirtualClock(time: time)
        )
        let plugin = AppsPlugin(context: context)
        plugin.now = time.now
        plugin.usageDatesReader = FakeUsageDatesReader(dates: [:])
        return Harness(plugin: plugin, workspace: workspace, settings: settings, fixture: fixture, time: time)
    }

    func suggestedKeys(_ plugin: AppsPlugin) async throws -> [String] {
        let source = try #require(plugin.suggestionSources.first)
        return try await source.suggestions(limit: 5).map(\.itemKey.rawValue)
    }

    @Test func anActivationBecomesASuggestion() async throws {
        let harness = try makeHarness()
        defer { harness.fixture.remove() }
        try await harness.plugin.activate()
        await harness.plugin.waitForRefresh()
        #expect(harness.plugin.tracker?.isRunning == true)
        harness.workspace.frontmost = { _ in "com.example.notes" }
        harness.workspace.activationsContinuation.yield(
            RunningApplication(processIdentifier: 9, bundleIdentifier: "com.example.notes"))
        #expect(await eventually { await harness.plugin.activity.snapshot.apps["com.example.notes"] != nil })
        harness.workspace.frontmost = { _ in nil }
        #expect(try await suggestedKeys(harness.plugin) == ["apps:com.example.notes"])
        // Spotlight is off, so the seed is skipped once the first scan finished.
        #expect(await eventually { await harness.plugin.activity.snapshot.seededAt == ActivityStore.seedSkipped })
        await harness.plugin.deactivate()
        await harness.plugin.deactivate()
        #expect(harness.plugin.tracker == nil)
    }

    @Test func turningSuggestionsOffStopsRecording() async throws {
        let harness = try makeHarness()
        defer { harness.fixture.remove() }
        try await harness.plugin.activate()
        await harness.plugin.waitForRefresh()
        let model = harness.plugin.makeSettingsModel()
        model.setSuggestionsEnabled(false)
        #expect(harness.plugin.tracker == nil)
        harness.workspace.frontmost = { _ in "com.example.mail" }
        harness.workspace.activationsContinuation.yield(
            RunningApplication(processIdentifier: 9, bundleIdentifier: "com.example.mail"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(harness.plugin.activity.snapshot.apps.isEmpty)
        #expect(try await suggestedKeys(harness.plugin).isEmpty)

        model.setSuggestionsEnabled(true)
        #expect(harness.plugin.tracker?.isRunning == true)
        await harness.plugin.deactivate()
    }

    #if DEBUG
    @Test func qaActivityFillsAnEmptyStore() async throws {
        let harness = try makeHarness { settings in
            settings.setValue(.string("com.example.mail=3,com.example.notes"), forKey: "plugins.apps.qaActivity")
            settings.setValue(.bool(false), forKey: "plugins.apps.qaLiveActivity")
        }
        defer { harness.fixture.remove() }
        try await harness.plugin.activate()
        await harness.plugin.waitForRefresh()
        #expect(harness.plugin.activity.snapshot.apps["com.example.mail"]?.useCount == 3)
        #expect(harness.plugin.activity.snapshot.apps["com.example.notes"]?.useCount == 1)
        #expect(try await suggestedKeys(harness.plugin) == ["apps:com.example.mail", "apps:com.example.notes"])
        // Live activity is off in QA mode: no tracker, no seed.
        #expect(harness.plugin.tracker == nil)
        #expect(harness.plugin.activity.snapshot.seededAt == nil)
        await harness.plugin.deactivate()
    }

    @Test func parsesQAActivity() {
        let parsed = AppsPlugin.parseQAActivity("com.example.a=3, com.example.b,=2,com.example.c=x")
        #expect(parsed.map(\.0) == ["com.example.a", "com.example.b", "com.example.c"])
        #expect(parsed.map(\.1) == [3, 1, 1])
    }
    #endif

    @Test func aNewerActivityFileStartsNothing() async throws {
        let harness = try makeHarness()
        defer { harness.fixture.remove() }
        let storage = harness.fixture.url("Storage")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try Data(#"{"version":2}"#.utf8).write(to: storage.appending(path: ActivityStore.fileName))
        try await harness.plugin.activate()
        await harness.plugin.waitForRefresh()
        #expect(harness.plugin.tracker == nil)
        #expect(try await suggestedKeys(harness.plugin).isEmpty)
        await harness.plugin.deactivate()
    }

    @Test func deactivateWritesPendingActivity() async throws {
        let harness = try makeHarness { settings in
            settings.setValue(.string("com.example.mail"), forKey: "plugins.apps.qaActivity")
        }
        defer { harness.fixture.remove() }
        try await harness.plugin.activate()
        await harness.plugin.deactivate()
        let file = harness.fixture.url("Storage").appending(path: ActivityStore.fileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Records which apps the seed read.
    final class RecordingUsageDatesReader: UsageDatesReader {
        let paths = Mutex<[String]>([])

        func usedDates(of url: URL) -> [Date] {
            paths.withLock { $0.append(url.lastPathComponent) }
            return []
        }
    }

    @Test func theSeedWaitsForTheFirstFinishedScan() async throws {
        let harness = try makeHarness { settings in
            settings.setValue(.bool(true), forKey: "plugins.apps.spotlight")
        }
        defer { harness.fixture.remove() }
        // A cached list is published at activation, before the scan.
        let cached = try AppScanner(roots: [harness.fixture.url("Apps")]).scan()
        try AppCache(directory: harness.plugin.context.cachesDirectory).save(cached)
        let reader = RecordingUsageDatesReader()
        harness.plugin.usageDatesReader = reader
        try await harness.plugin.activate()
        #expect(!harness.plugin.store.apps.isEmpty)
        #expect(harness.plugin.seedPending)
        #expect(harness.plugin.seedTask == nil)
        #expect(reader.paths.withLock { $0 }.isEmpty)

        // Spotlight is on, so its first answer may replace the scan that is running: wait until a scan that
        // was not replaced has seeded.
        for _ in 0..<500 {
            await harness.plugin.waitForRefresh()
            await harness.plugin.waitForSeed()
            if !reader.paths.withLock({ $0 }).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(reader.paths.withLock { Set($0) } == ["Mail.app", "Notes.app"])
        let seededAt = harness.plugin.activity.snapshot.seededAt
        #expect(seededAt != nil && seededAt != ActivityStore.seedSkipped)
        await harness.plugin.deactivate()
    }

    @Test func hidingAnAppUpdatesAnOpenSettingsPane() async throws {
        let harness = try makeHarness()
        defer { harness.fixture.remove() }
        try await harness.plugin.activate()
        await harness.plugin.waitForRefresh()
        let model = harness.plugin.makeSettingsModel()
        await harness.plugin.activity.recordUse(of: "com.example.notes", at: harness.time.date)
        let source = try #require(harness.plugin.suggestionSources.first)
        let candidate = try #require(try await source.suggestions(limit: 5).first)
        let hide = try #require(source.actions(for: candidate).first { $0.id == AppSuggestionSource.hideID })
        try await hide.perform(ActionContext(previousApp: nil, panel: NoPanel()))
        #expect(model.hidden == ["com.example.notes"])
        await harness.plugin.deactivate()
    }
}
