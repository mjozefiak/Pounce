import Foundation
import PounceKit
import Testing

@testable import PounceApp

/// A plugin with one search section and no lifecycle logging (the shared `LifecycleLog` belongs to the
/// `PluginHostTests`).
final class FirstPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "first", displayName: "First", symbolName: "1.circle", order: 1)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [InstantSource(id: "first.instant")] }
}

/// A plugin with a search section and a status line, ordered after `FirstPlugin`.
final class StatusPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "status", displayName: "Status", symbolName: "s.circle", order: 9)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [StatusSource()] }
    var searchStatus: [SearchStatus] {
        [
            SearchStatus(
                id: "status.progress", symbolName: "hourglass", message: "Indexing", style: .progress,
                actions: [SearchStatusAction(id: "status.open", title: "Set Up", kind: .openSettings)])
        ]
    }
}

struct StatusSource: SearchSource {
    let id: SourceID = "status.source"

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        [
            Candidate(
                itemKey: ItemKey(pluginID: "status", key: "one"), title: "Status \(query.raw)",
                icon: .symbol("circle"), match: MatchResult(tier: .exact, score: 1))
        ]
    }
}

@Suite struct SectionOrderTests {
    @Test func savedIdsComeFirstThenManifestOrder() {
        let ids: [PluginID] = ["apps", "files", "clipboard"]
        #expect(SectionOrder.sorted(ids, saved: []) == ids)
        #expect(SectionOrder.sorted(ids, saved: ["files"]) == ["files", "apps", "clipboard"])
        #expect(
            SectionOrder.sorted(ids, saved: ["gone", "clipboard", "clipboard", "apps"]) == [
                "clipboard", "apps", "files",
            ])
    }

    @Test func movingSwapsNeighboursAndStopsAtTheEnds() {
        let ids: [PluginID] = ["apps", "files"]
        #expect(SectionOrder.moving("files", by: -1, in: ids) == ["files", "apps"])
        #expect(SectionOrder.moving("apps", by: -1, in: ids) == ids)
        #expect(SectionOrder.moving("files", by: 1, in: ids) == ids)
        #expect(SectionOrder.moving("missing", by: 1, in: ids) == ids)
    }

    @Test func appSettingsPersistTheOrder() {
        let store = InMemorySettingsStore()
        let settings = AppSettings(store: store)
        #expect(settings.sectionOrder.isEmpty)
        settings.sectionOrder = ["files", "apps"]
        #expect(store.value(forKey: SettingsKeys.sectionOrder) == .stringArray(["files", "apps"]))
        #expect(AppSettings(store: store).sectionOrder == ["files", "apps"])
    }
}

@MainActor
@Suite struct SearchStatusShellTests {
    @Test func sectionsFollowTheSavedOrderAndCarryStatuses() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([FirstPlugin.self, StatusPlugin.self])
        await host.start()
        var order: [String] = []
        let coordinator = SearchCoordinator(host: host, usage: SpyUsageRecorder(), sectionOrder: { order })

        let first = try #require(await coordinator.search("res"))
        #expect(first.sections.map(\.id) == ["first:first.instant", "status:status.source"])
        #expect(first.statuses.map(\.id) == ["status|status.progress"])

        order = ["status"]
        let second = try #require(await coordinator.search("res"))
        #expect(second.sections.map(\.id) == ["status:status.source", "first:first.instant"])

        let empty = try #require(await coordinator.search(""))
        #expect(empty.statuses.count == 1)

        await host.setEnabled(false, for: "status")
        let disabled = try #require(await coordinator.search("res"))
        #expect(disabled.statuses.isEmpty)
        await host.stop()
    }

    @Test func statusActionsRunOrOpenThePluginSettings() async throws {
        let model = PanelModel { _ in .empty }
        var opened: [PluginID] = []
        model.openPluginSettings = { opened.append($0) }
        let status = PanelStatus(
            pluginID: "status",
            status: SearchStatus(
                id: "s", symbolName: "hand.raised", message: "Notice",
                actions: [SearchStatusAction(id: "s.open", title: "Set Up", kind: .openSettings)]))
        model.perform(status.status.actions[0], of: status)
        #expect(opened == ["status"])

        var ran = 0
        let run = SearchStatusAction(id: "s.run", title: "Run", kind: .run({ ran += 1 }))
        model.perform(run, of: status)
        #expect(ran == 1)
    }

    @Test func statusLinesMakeThePanelTaller() async throws {
        let status = PanelStatus(
            pluginID: "status", status: SearchStatus(id: "s", symbolName: "hourglass", message: "Indexing"))
        let model = PanelModel { query in
            SearchResults(query: NormalizedQuery(raw: query, normalized: query), sections: [], statuses: [status])
        }
        let before = model.preferredHeight
        model.updateQuery("x")
        await model.waitForSearch()
        #expect(model.results.statuses.count == 1)
        #expect(model.preferredHeight >= before + PanelModel.Metrics.statusHeight)
    }
}

@Suite struct FullDiskAccessProbeTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "pounce-fda-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readableFolderMeansGranted() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(
            at: home.appending(path: "Library/Safari"), withIntermediateDirectories: true)
        #expect(FullDiskAccessProbe(home: home.path).status() == .granted)
    }

    @Test func unreadableFolderMeansDenied() throws {
        let home = try makeDirectory()
        let locked = home.appending(path: "Library/Safari")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: home)
        }
        #expect(FullDiskAccessProbe(home: home.path).status() == .denied)
    }

    @Test func missingFoldersMeanNotDetermined() throws {
        let home = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(FullDiskAccessProbe(home: home.path).status() == .notDetermined)
    }
}

#if DEBUG
@Suite struct QAFullDiskAccessOptionTests {
    @Test func parsesTheOverride() throws {
        #expect(try QAOptions.parse(["--qa-full-disk-access", "granted"])?.fullDiskAccess == .granted)
        #expect(try QAOptions.parse(["--qa-full-disk-access", "denied"])?.fullDiskAccess == .denied)
        #expect(try QAOptions.parse(["--qa"])?.fullDiskAccess == nil)
        let order = try QAOptions.parse(["--qa-setting", "app.sectionOrder=files,apps"])
        #expect(order?.settings["app.sectionOrder"] == .stringArray(["files", "apps"]))
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-full-disk-access", "maybe")) {
            _ = try QAOptions.parse(["--qa-full-disk-access", "maybe"])
        }
    }
}
#endif

#if DEBUG
@Suite struct QAFileIndexIsolationTests {
    @Test func withoutFixtureSettingsTheIndexOnlySeesAnEmptyFolder() {
        let settings = AppEnvironment.qaFileIndexSettings([:], emptyHome: "/tmp/qa/files-home")
        #expect(settings["plugins.files.qaHome"] == .string("/tmp/qa/files-home"))
        #expect(settings["plugins.files.roots"] == .string("/tmp/qa/files-home"))
    }

    @Test func fixtureSettingsAreKept() {
        let given: [String: SettingValue] = [
            "plugins.files.qaHome": .string("/tmp/pounce-p3-x/home"),
            "plugins.files.roots": .string("/tmp/pounce-p3-x/home"),
        ]
        #expect(AppEnvironment.qaFileIndexSettings(given, emptyHome: "/tmp/qa/files-home") == given)
        let homeOnly = AppEnvironment.qaFileIndexSettings(
            ["plugins.files.qaHome": .string("/tmp/pounce-p3-x/home")], emptyHome: "/tmp/qa/files-home")
        #expect(homeOnly["plugins.files.roots"] == .string("/tmp/pounce-p3-x/home"))
    }
}
#endif
