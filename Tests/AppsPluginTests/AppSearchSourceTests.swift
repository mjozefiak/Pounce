import Foundation
import PounceCore
import PounceKit
import Synchronization
import Testing

@testable import AppsPlugin

private let records = [
    AppRecord(
        bundleIdentifier: "com.microsoft.VSCode", path: "/Applications/Visual Studio Code.app",
        name: "Visual Studio Code", aliases: ["Code"]),
    AppRecord(
        bundleIdentifier: "com.apple.calculator", path: "/System/Applications/Calculator.app",
        name: "Kalkulator", aliases: ["Calculator"]),
    AppRecord(
        bundleIdentifier: "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app",
        name: "Terminal"),
    AppRecord(bundleIdentifier: "com.apple.TextEdit", path: "/System/Applications/TextEdit.app", name: "TextEdit"),
]

@MainActor
private func makeSource(usage: RecordingUsage = RecordingUsage(), workspace: RecordingWorkspace = RecordingWorkspace())
    -> AppSearchSource
{
    let store = AppStore()
    store.publish(records)
    return AppSearchSource(store: store, usage: usage, workspace: workspace, clock: { Date(timeIntervalSince1970: 0) })
}

/// The app search source: tiers, aliases, empty query, cancellation (spec steps 1.3 and 1.5).
@MainActor
@Suite struct AppSearchSourceTests {
    @Test func acronymAndLocalizedNamesMatch() async throws {
        let source = makeSource()
        let vsc = try await source.search(TextNormalizer.query("vsc"), limit: 10)
        #expect(vsc.first?.title == "Visual Studio Code")
        #expect(vsc.first?.match.tier == .wordStart)
        #expect(vsc.first?.itemKey.rawValue == "apps:com.microsoft.VSCode")

        let kalk = try await source.search(TextNormalizer.query("kalk"), limit: 10)
        #expect(kalk.map(\.title) == ["Kalkulator"])
        #expect(kalk.first?.match.highlightRanges == [0..<4])
    }

    @Test func aliasMatchesKeepTheirTierWithoutHighlights() async throws {
        let source = makeSource()
        let results = try await source.search(TextNormalizer.query("calc"), limit: 10)
        #expect(results.map(\.title) == ["Kalkulator"])
        #expect(results.first?.match.tier == .prefix)
        #expect(results.first?.match.highlightRanges == [])
        #expect(
            results.first?.icon
                == .file(URL(filePath: "/System/Applications/Calculator.app", directoryHint: .isDirectory)))
    }

    @Test func ordersByTierAndRespectsTheLimit() async throws {
        let source = makeSource()
        let results = try await source.search(TextNormalizer.query("te"), limit: 10)
        #expect(results.map(\.title) == ["Terminal", "TextEdit", "Visual Studio Code"])
        #expect(results.last?.match.tier == .fuzzy)
        #expect(results.prefix(2).allSatisfy { $0.match.tier == .prefix })
        #expect(try await source.search(TextNormalizer.query("te"), limit: 1).count == 1)
        #expect(try await source.search(TextNormalizer.query("zzz"), limit: 10).isEmpty)
    }

    @Test func emptyQueryReturnsRecentlyUsedAppsOnly() async throws {
        let usage = RecordingUsage()
        let source = makeSource(usage: usage)
        #expect(try await source.search(TextNormalizer.query(""), limit: 8).isEmpty)

        let terminal = ItemKey(pluginID: "apps", key: "com.apple.Terminal")
        try await usage.recordUse(of: terminal, queryPrefix: nil, at: Date())
        try await usage.recordUse(of: ItemKey(pluginID: "apps", key: "com.gone.app"), queryPrefix: nil, at: Date())
        let recent = try await source.search(TextNormalizer.query(""), limit: 8)
        #expect(recent.map(\.title) == ["Terminal"])
    }

    @Test func cancelledSearchThrows() async throws {
        let source = makeSource()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await source.search(TextNormalizer.query("t"), limit: 10)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Spec step 1.5: Return opens the app with the launch options, Command-Return reveals it.
@MainActor
@Suite struct AppActionsTests {
    @Test func openActionLaunchesWithOptionsAndRecordsTheQueryPrefix() async throws {
        let usage = RecordingUsage()
        let workspace = RecordingWorkspace()
        let source = makeSource(usage: usage, workspace: workspace)
        let candidate = try #require(try await source.search(TextNormalizer.query("termi"), limit: 1).first)
        let actions = source.actions(for: candidate)
        #expect(actions.map(\.id) == ["apps.open", "apps.reveal"])
        #expect(actions[0].shortcut == KeyShortcut(key: "\r"))
        #expect(actions[1].shortcut == KeyShortcut(key: "\r", modifiers: .command))

        let context = ActionContext(previousApp: nil, panel: NoPanel(), query: TextNormalizer.query("termi"))
        try await actions[0].perform(context)
        let url = URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
        let expected = ApplicationOpenOptions(
            activates: true,
            addsToRecentItems: true,
            promptsUserIfNeeded: true,
            yieldsActivationTo: "com.apple.Terminal"
        )
        #expect(workspace.calls == [.openApplication(url, expected)])
        let uses = await usage.uses
        #expect(uses.map(\.0.rawValue) == ["apps:com.apple.Terminal"])
        #expect(uses.map(\.1) == ["term"])

        try await actions[1].perform(ActionContext(previousApp: nil, panel: NoPanel()))
        #expect(workspace.calls.last == .reveal([url]))
        #expect(await usage.uses.count == 1)
    }

    @Test func failedLaunchThrowsAndRecordsNothing() async throws {
        struct LaunchFailed: Error {}
        let usage = RecordingUsage()
        let workspace = RecordingWorkspace()
        workspace.failure = LaunchFailed()
        let source = makeSource(usage: usage, workspace: workspace)
        let candidate = try #require(try await source.search(TextNormalizer.query("textedit"), limit: 1).first)
        let open = try #require(source.actions(for: candidate).first)
        await #expect(throws: LaunchFailed.self) {
            try await open.perform(ActionContext(previousApp: nil, panel: NoPanel()))
        }
        #expect(await usage.uses.isEmpty)
    }

    @Test func unknownCandidatesHaveNoActions() {
        let source = makeSource()
        let stranger = Candidate(
            itemKey: ItemKey(pluginID: "files", key: "/tmp/a"),
            title: "a",
            icon: .symbol("doc"),
            match: MatchResult(tier: .exact, score: 1)
        )
        #expect(source.actions(for: stranger).isEmpty)
    }

    @Test func launcherOptionsYieldActivationToTheApp() {
        let record = AppRecord(bundleIdentifier: "com.example.a", path: "/Applications/A.app", name: "A")
        let options = AppLauncher.options(for: record)
        #expect(options.activates)
        #expect(options.yieldsActivationTo == "com.example.a")
    }
}

/// The plugin's lifecycle against a fixture root, with Spotlight off.
@MainActor
@Suite struct AppsPluginLifecycleTests {
    @Test func activationScansTheConfiguredRootAndCachesTheList() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.makeApp("Apps/Notes.app", identifier: "com.example.notes", name: "Notes")
        let settings = MemorySettings()
        settings.setValue(.string(fixture.url("Apps").path), forKey: "plugins.apps.roots")
        settings.setValue(.bool(false), forKey: "plugins.apps.spotlight")
        let signals = Mutex(0)
        let context = makeContext(
            storage: fixture.url("Storage"),
            settings: settings,
            usage: RecordingUsage(),
            workspace: RecordingWorkspace()
        ) { signals.withLock { $0 += 1 } }
        let plugin = AppsPlugin(context: context)
        #expect(AppsPlugin.manifest.id == "apps")
        #expect(plugin.roots == [fixture.url("Apps")])

        try await plugin.activate()
        await plugin.waitForRefresh()
        let source = try #require(plugin.searchSources.first)
        let results = try await source.search(TextNormalizer.query("not"), limit: 5)
        #expect(results.map(\.itemKey.rawValue) == ["apps:com.example.notes"])
        #expect(FileManager.default.fileExists(atPath: fixture.url("Storage/Caches/apps.json").path))
        // The panel is told to search again once the scan has published the list.
        #expect(signals.withLock { $0 } == 1)

        await plugin.deactivate()
        await plugin.deactivate()

        // A new instance answers from the cache before its first scan.
        let cached = AppsPlugin(context: context)
        settings.setValue(.string(fixture.url("Missing").path), forKey: "plugins.apps.roots")
        try await cached.activate()
        let fromCache = try await cached.searchSources[0].search(TextNormalizer.query("notes"), limit: 5)
        #expect(fromCache.count == 1)
        await cached.deactivate()
    }
}
