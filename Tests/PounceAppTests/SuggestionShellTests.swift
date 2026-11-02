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
