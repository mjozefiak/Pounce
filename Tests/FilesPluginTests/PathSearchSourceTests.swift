import Foundation
import PounceCore
import PounceKit
import Testing

@testable import FilesPlugin

@MainActor
@Suite("Path search source")
struct PathSearchSourceTests {
    private func source(_ harness: PluginHarness) throws -> any SearchSource {
        try #require(harness.plugin.searchSources.first { $0.id == "files.path" })
    }

    private func titles(_ harness: PluginHarness, _ text: String) async throws -> [String] {
        try await source(harness).search(TextNormalizer.query(text), limit: 50).map(\.title)
    }

    @Test func pastedPathThroughHiddenFoldersListsTheFolderAndItsContents() async throws {
        let harness = try PluginHarness()
        try harness.directory.make([
            "home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/PLAN.md",
            "home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/HANDOFF.md",
            "home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/screenshots/",
            "home/Projects/ng/.ai/runs/2026-10-27-qa-fixes/.checkpoints/",
        ])
        let folder = harness.directory.sub("home/Projects/ng/.ai/runs/2026-10-27-qa-fixes")
        #expect(try await titles(harness, folder + "/") == ["2026-10-27-qa-fixes", "screenshots", "HANDOFF.md", "PLAN.md"])
        #expect(try await titles(harness, "~/Projects/ng/.ai/runs/2026-10-27-qa-fixes/") == [
            "2026-10-27-qa-fixes", "screenshots", "HANDOFF.md", "PLAN.md",
        ])
    }

    @Test func textAfterTheLastSlashFiltersAndAnExactNameComesFirst() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/r/2026-10-27-a/", "home/r/2026-10-24-b/", "home/r/notes.txt", "home/r/2026"])
        #expect(try await titles(harness, "~/r/2026-10") == ["2026-10-24-b", "2026-10-27-a"])
        #expect(try await titles(harness, "~/r/2026").first == "2026")
        #expect(try await titles(harness, "~/r/zzz").isEmpty)
    }

    @Test func hiddenItemsInsideNeedADotFilterOrTheSetting() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/p/.env", "home/p/app.swift"])
        #expect(try await titles(harness, "~/p/") == ["p", "app.swift"])
        #expect(try await titles(harness, "~/p/.e") == [".env"])
        harness.plugin.settings.setIncludesHidden(true)
        #expect(try await titles(harness, "~/p/") == ["p", ".env", "app.swift"])
    }

    @Test func excludedFoldersAreListedWhenTyped() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/app/node_modules/left-pad/index.js"])
        #expect(try await titles(harness, "~/app/node_modules/") == ["node_modules", "left-pad"])
    }

    @Test func protectedFolderShowsOnlyItsRowWithoutFullDiskAccess() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/Documents/Invoices/a.pdf"])
        let results = try await source(harness).search(TextNormalizer.query("~/Documents/Invoices/"), limit: 50)
        #expect(results.map(\.title) == ["Invoices"])
        #expect(results.first?.subtitle == "~/Documents · " + PathSearchSource.protectedNote)

        harness.permissions.fullDiskAccess = .granted
        harness.plugin.refreshAccess()
        #expect(try await titles(harness, "~/Documents/Invoices/") == ["Invoices", "a.pdf"])
    }

    @Test func missingPathGivesNothingAndOtherQueriesAreLeftToTheIndex() async throws {
        let harness = try PluginHarness()
        #expect(try await titles(harness, "~/nothing/here/").isEmpty)
        #expect(try await titles(harness, "budget").isEmpty)
        let names = try #require(harness.plugin.searchSources.first { $0.id == "files.names" })
        #expect(try await names.search(TextNormalizer.query("~/"), limit: 5).isEmpty)
    }

    @Test func resultsCarryTheTypedPathAsKey() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/p/a.txt"])
        let results = try await source(harness).search(TextNormalizer.query("~/p/a"), limit: 50)
        #expect(results.map(\.itemKey) == [ItemKey(pluginID: "files", key: harness.directory.sub("home/p/a.txt"))])
        #expect(results.first?.subtitle == "~/p")
    }

    @Test func orderSurvivesTheShellRanker() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/p/b/", "home/p/a.txt", "home/p/c.txt"])
        let results = try await source(harness).search(TextNormalizer.query("~/p/"), limit: 50)
        let ranker = Ranker(now: Date())
        #expect(ranker.rank(results, stats: [:]).map(\.title) == ["p", "b", "a.txt", "c.txt"])

        // A heavily used file may rise above folders within its tier, never above the folder row.
        let used = try #require(results.first { $0.title == "c.txt" })
        let stats = [used.itemKey: UsageStats(frecency: 50, lastUsedAt: Date(), useCount: 9, queryAssociationCount: 0)]
        #expect(ranker.rank(results, stats: stats).map(\.title) == ["p", "c.txt", "b", "a.txt"])
    }

    @Test func usesAreRecordedWithoutAQueryPrefix() async throws {
        let harness = try PluginHarness()
        try harness.directory.make(["home/p/a.txt"])
        let source = try source(harness)
        let candidate = try #require(try await source.search(TextNormalizer.query("~/p/a"), limit: 5).first)
        let context = ActionContext(previousApp: nil, panel: FakePanel(), query: TextNormalizer.query("~/p/a"))
        try await source.actions(for: candidate)[0].perform(context)
        let uses = await harness.usage.uses
        #expect(uses.count == 1)
        #expect(uses.first?.0 == candidate.itemKey)
        #expect(uses.first?.1 == nil)
        #expect(harness.workspace.opened.map(\.path) == [harness.directory.sub("home/p/a.txt")])
    }
}
