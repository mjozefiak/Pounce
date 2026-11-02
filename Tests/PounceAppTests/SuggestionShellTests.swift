import Foundation
import PounceKit
import Synchronization
import Testing

@testable import PounceApp

/// Suggests fixed items, in a fixed order, and records how often it was asked.
nonisolated struct FixedSuggestions: SuggestionSource {
    let id: SourceID
    let pluginID: PluginID
    let keys: [String]
    var badges: [String: String] = [:]

    func suggestions(limit: Int) async throws -> [Candidate] {
        keys.prefix(limit).map { key in
            Candidate(
                itemKey: ItemKey(pluginID: pluginID, key: key), title: key.capitalized, icon: .symbol("app"),
                match: MatchResult(tier: .exact, score: 0), badge: badges[key])
        }
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        [
            ResultAction(
                id: "open", title: "Open", symbolName: "arrow.up.forward.app", shortcut: KeyShortcut(key: "\r")
            ) {
                _ in
                SuggestionLog.shared.record("open \(candidate.itemKey.key)")
            }
        ]
    }
}

/// What suggestion actions ran.
nonisolated final class SuggestionLog: Sendable {
    static let shared = SuggestionLog()
    private let events = Mutex<[String]>([])

    var all: [String] { events.withLock { $0 } }
    func record(_ event: String) { events.withLock { $0.append(event) } }
    func reset() { events.withLock { $0 = [] } }
}

nonisolated struct FailingSuggestions: SuggestionSource {
    let id: SourceID = "failing.suggestions"

    func suggestions(limit: Int) async throws -> [Candidate] { throw TestError.searchFailed }
}

/// Suggests nothing of its own: the shell must behave exactly as before.
final class PlainPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "plain", displayName: "Plain", symbolName: "p.circle", order: 1)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [InstantSource(id: "plain.instant")] }
}

@MainActor
@Suite struct SuggestionContractShellTests {
    @Test func aPluginWithoutSuggestionsAddsNoSource() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([PlainPlugin.self])
        await host.start()
        #expect(host.activeSuggestionSources.isEmpty)
        #expect(await host.querySuggestions(limit: 5).isEmpty)
        let coordinator = SearchCoordinator(host: host, usage: SpyUsageRecorder())
        let empty = try #require(await coordinator.search(""))
        #expect(empty.sections.isEmpty)
        await host.stop()
    }

    @Test func theAdapterForwardsSuggestionsAndActions() async throws {
        let source = FixedSuggestions(id: "fixed", pluginID: "plain", keys: ["a", "b", "c"])
        let adapter = SuggestionSourceAdapter(source: source)
        #expect(adapter.id == "fixed")
        let found = try await adapter.search(NormalizedQuery(raw: "", normalized: ""), limit: 2)
        #expect(found.map(\.itemKey.key) == ["a", "b"])
        #expect(adapter.actions(for: found[0]).map(\.id) == ["open"])
    }
}

/// Answers the empty query with `k1`…`k12`, and suggests `k1`, `k2` and `s1`.
final class RecentAndSuggestingPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "lib", displayName: "Library", symbolName: "books.vertical", order: 1)

    init(context: PluginContext) {}

    var searchSources: [any SearchSource] { [NumberedSource()] }
    var suggestionSources: [any SuggestionSource] {
        [FixedSuggestions(id: "lib.suggestions", pluginID: "lib", keys: ["k1", "k2", "s1"], badges: ["k2": "Running"])]
    }
}

nonisolated struct NumberedSource: SearchSource {
    let id: SourceID = "lib.items"

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        (1...12).map { number in
            Candidate(
                itemKey: ItemKey(pluginID: "lib", key: "k\(number)"), title: "Item \(number)",
                icon: .symbol("doc"), match: MatchResult(tier: .exact, score: 0))
        }
    }
}

/// Suggests `x` and a duplicate of `lib:k1`.
final class OtherSuggestingPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "other", displayName: "Other", symbolName: "o.circle", order: 5)

    init(context: PluginContext) {}

    var suggestionSources: [any SuggestionSource] {
        [
            FixedSuggestions(id: "other.x", pluginID: "other", keys: ["x", "y", "z"]),
            FixedSuggestions(id: "other.dup", pluginID: "lib", keys: ["k1"]),
        ]
    }
}

final class BrokenSuggestionsPlugin: PouncePlugin {
    static let manifest = PluginManifest(id: "broken", displayName: "Broken", symbolName: "b.circle", order: 0)

    init(context: PluginContext) {}

    var suggestionSources: [any SuggestionSource] { [FailingSuggestions(), StuckSuggestions()] }
}

/// Never answers and ignores cancellation.
nonisolated struct StuckSuggestions: SuggestionSource {
    let id: SourceID = "stuck.suggestions"

    func suggestions(limit: Int) async throws -> [Candidate] {
        await Task.detached { blockCurrentThread(microseconds: 1_000_000) }.value
        return []
    }
}

/// `lib:kN` has frecency 100 − N; records which keys were asked for.
actor NumberedUsage: UsageRecorder {
    private(set) var requested: [ItemKey] = []
    private(set) var recorded = 0

    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws { recorded += 1 }

    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        requested.append(contentsOf: keys)
        var result: [ItemKey: UsageStats] = [:]
        for key in keys where key.pluginID == "lib" {
            guard let number = Int(key.key.dropFirst()) else { continue }
            result[key] = UsageStats(
                frecency: Double(100 - number), lastUsedAt: Date(), useCount: 1, queryAssociationCount: 0)
        }
        return result
    }
}

@MainActor
@Suite struct SuggestedSectionTests {
    @Test func suggestionsComeFirstAndRecentlyUsedStaysFullWithoutDuplicates() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([RecentAndSuggestingPlugin.self])
        await host.start()
        let usage = NumberedUsage()
        let coordinator = SearchCoordinator(host: host, usage: usage)

        let empty = try #require(await coordinator.search(""))
        #expect(empty.sections.map(\.kind) == [.suggested, .recent])
        let suggested = empty.sections[0]
        #expect(suggested.items.map(\.candidate.itemKey.rawValue) == ["lib:k1", "lib:k2", "lib:s1"])
        #expect(suggested.items.map(\.id) == ["suggested|lib:k1", "suggested|lib:k2", "suggested|lib:s1"])
        #expect(suggested.items[1].candidate.badge == "Running")
        #expect(String(localized: suggested.title) == "Suggested")
        let recent = empty.sections[1].items.map(\.candidate.itemKey.key)
        #expect(recent == ["k3", "k4", "k5", "k6", "k7", "k8", "k9", "k10"])
        // Suggestions are never looked up in ranking.sqlite.
        #expect(!(await usage.requested).contains(ItemKey(pluginID: "lib", key: "s1")))
        #expect(await usage.recorded == 0)

        // A typed query has no suggestions.
        let typed = try #require(await coordinator.search("item"))
        #expect(!typed.sections.contains { $0.kind == .suggested })
        await host.stop()
    }

    @Test func pluginsFollowTheSectionOrderAndTheSectionHoldsFive() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([RecentAndSuggestingPlugin.self, OtherSuggestingPlugin.self])
        await host.start()
        var order: [String] = []
        let coordinator = SearchCoordinator(host: host, usage: NumberedUsage(), sectionOrder: { order })

        let first = try #require(await coordinator.search(""))
        #expect(
            first.sections[0].items.map(\.candidate.itemKey.rawValue) == [
                "lib:k1", "lib:k2", "lib:s1", "other:x", "other:y",
            ])

        order = ["other"]
        let second = try #require(await coordinator.search(""))
        #expect(
            second.sections[0].items.map(\.candidate.itemKey.rawValue) == [
                "other:x", "other:y", "other:z", "lib:k1", "lib:k2",
            ])
        await host.stop()
    }

    @Test func aFailingOrSlowSourceLosesOnlyTheSuggestions() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([BrokenSuggestionsPlugin.self, PlainPlugin.self], budget: .milliseconds(50))
        await host.start()
        let coordinator = SearchCoordinator(host: host, usage: SpyUsageRecorder())
        let start = ContinuousClock.now
        let empty = try #require(await coordinator.search(""))
        #expect(ContinuousClock.now - start < .milliseconds(900))
        #expect(!empty.sections.contains { $0.kind == .suggested })
        let typed = try #require(await coordinator.search("res"))
        #expect(typed.sections.map(\.id) == ["plain:plain.instant"])
        await host.stop()
    }

    @Test func noSuggestionsMeansNoSection() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let host = test.makeHost([OtherSuggestingPlugin.self])
        await host.start()
        await host.setEnabled(false, for: "other")
        let coordinator = SearchCoordinator(host: host, usage: SpyUsageRecorder())
        let empty = try #require(await coordinator.search(""))
        #expect(empty.sections.isEmpty)
        await host.stop()
    }
}

#if DEBUG
@Suite struct QAAppActivityTests {
    @Test func activityArgumentsBecomePluginSettingKeys() throws {
        let options = try #require(
            try QAOptions.parse([
                "Pounce", "--qa-activity", "com.example.notes=4", "--qa-activity", "com.example.mail",
            ]))
        #expect(options.appActivity == ["com.example.notes=4", "com.example.mail"])
        #expect(!options.liveAppActivity)
        let settings = AppEnvironment.qaAppActivitySettings(
            [:], activity: options.appActivity, live: options.liveAppActivity)
        #expect(settings["plugins.apps.qaActivity"] == .string("com.example.notes=4,com.example.mail"))
        #expect(settings["plugins.apps.qaLiveActivity"] == .bool(false))
    }

    @Test func liveActivityIsOffUnlessAsked() throws {
        #expect(
            AppEnvironment.qaAppActivitySettings([:], activity: [], live: false) == [
                "plugins.apps.qaLiveActivity": .bool(false)
            ])
        let live = try #require(try QAOptions.parse(["Pounce", "--qa-activity-live"]))
        #expect(live.liveAppActivity)
        #expect(
            AppEnvironment.qaAppActivitySettings([:], activity: [], live: true) == [
                "plugins.apps.qaLiveActivity": .bool(true)
            ])
    }

    @Test(arguments: ["", "=3", "com.example.a=0", "com.example.a=x", "a,b", "--qa"])
    func rejectsMalformedActivity(_ value: String) {
        #expect(throws: QAOptions.ParseError.invalidValue("--qa-activity", value)) {
            try QAOptions.parse(["Pounce", "--qa-activity", value])
        }
    }
}
#endif

@MainActor
@Suite struct SuggestionKeyboardTests {
    func makeModel(_ test: TestEnvironment) async -> (PanelModel, PluginHost, FakePresenter) {
        let host = test.makeHost([RecentAndSuggestingPlugin.self])
        await host.start()
        let coordinator = SearchCoordinator(host: host, usage: NumberedUsage())
        let model = PanelModel { await coordinator.search($0) }
        let presenter = FakePresenter()
        model.presenter = presenter
        model.panelPresenter = presenter
        model.announce = { _ in }
        return (model, host, presenter)
    }

    @Test func commandNumbersOpenTheNthSuggestion() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let (model, host, presenter) = await makeModel(test)
        model.show()
        await model.waitForSearch()
        #expect(model.selectedItem?.id == "suggested|lib:k1")
        #expect(model.footerActionLimit == 3)

        #expect(model.performSuggestion(at: 1))
        await model.waitForAction()
        #expect(SuggestionLog.shared.all.contains("open k2"))
        #expect(!model.isVisible)
        #expect(presenter.dismissed == 1)

        // There is no fourth suggestion; Command-6 and later are never suggestions.
        model.show()
        await model.waitForSearch()
        #expect(!model.performSuggestion(at: 3))
        #expect(!model.performSuggestion(at: 5))
        model.moveSelection(by: 4)
        #expect(model.selectedSection?.kind == .recent)
        #expect(model.footerActionLimit == 2)
        await host.stop()
    }

    @Test func aTypedQueryLeavesCommandNumbersAlone() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let (model, host, _) = await makeModel(test)
        model.show()
        await model.waitForSearch()
        model.updateQuery("item")
        await model.waitForSearch()
        #expect(!model.performSuggestion(at: 0))
        #expect(model.isVisible)
        await host.stop()
    }

    @Test func listModeFiltersKeepCommandNumbers() async throws {
        let test = try TestEnvironment()
        defer { test.tearDown() }
        let coordinator = SearchCoordinator(host: test.makeHost([]), usage: SpyUsageRecorder())
        let model = PanelModel { _ in .empty }
        let mode = notesMode(log: ActionLog(), opened: ActionLog())
        model.panelMode = { $0 == "notes" ? mode : nil }
        model.modeSearch = { mode, text, filter in await coordinator.search(mode: mode, raw: text, filter: filter) }
        model.announce = { _ in }
        model.show(mode: .plugin("notes"))
        await model.waitForSearch()
        #expect(!model.performSuggestion(at: 0))
        #expect(model.toggleFilter(at: 0))
    }

    @Test func rowsSpeakTheBadgeKindAndShortcut() {
        let candidate = Candidate(
            itemKey: ItemKey(pluginID: "apps", key: "com.example.chat"), title: "Chat", icon: .symbol("app"),
            match: MatchResult(tier: .exact, score: 0), badge: "Running")
        let item = ResultItem(
            id: "suggested|apps:com.example.chat", candidate: candidate,
            source: SuggestionSourceAdapter(source: FixedSuggestions(id: "x", pluginID: "apps", keys: [])),
            kind: "Suggested")
        #expect(ResultRow.accessibilityValue(item, shortcutNumber: 1) == "Running, Suggested, Command-1")
        #expect(ResultRow.accessibilityValue(item, shortcutNumber: nil) == "Running, Suggested")
    }
}
