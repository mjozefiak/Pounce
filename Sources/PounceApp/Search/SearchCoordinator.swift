import Foundation
import PounceCore
import PounceKit
import os

/// One row in the panel.
struct ResultItem: Identifiable {
    /// Unique within one set of results: section id plus item key.
    let id: String
    let candidate: Candidate
    let source: any SearchSource
    /// The section's name, read by VoiceOver as the row's kind.
    let kind: LocalizedStringResource
}

/// A titled group of rows: one plugin's results, the recently used items, or a plugin that is
/// unavailable because it failed to start.
struct ResultSection: Identifiable {
    enum Kind: Equatable {
        case results
        case recent
        /// The plugin is in the `failed` state; the row links to Settings.
        case unavailable(PluginID)
    }

    let id: String
    let title: LocalizedStringResource
    let symbolName: String
    let kind: Kind
    let items: [ResultItem]
}

/// A plugin's `SearchStatus` line in the panel.
struct PanelStatus: Identifiable {
    let pluginID: PluginID
    let status: SearchStatus

    var id: String { "\(pluginID.rawValue)|\(status.id)" }
}

/// What a query produced.
struct SearchResults {
    let query: NormalizedQuery
    let sections: [ResultSection]
    /// Status lines of the active plugins (search mode only). Added in Phase 3.
    var statuses: [PanelStatus] = []

    static let empty = SearchResults(query: NormalizedQuery(raw: "", normalized: ""), sections: [])

    var items: [ResultItem] { sections.flatMap(\.items) }
}

/// Sends a query to every active source (in parallel, each with its budget, through `PluginHost`),
/// reads usage statistics once, and ranks each section with the `Ranker`. Sections follow the user's
/// order (`app.sectionOrder`, issue #5), then `manifest.order`. An empty query shows the most recently
/// used items across all sources. Every answer also carries the active plugins' status lines.
final class SearchCoordinator {
    static let sourceLimit = 50
    static let sectionLimit = 20
    static let recentLimit = 8

    private let host: PluginHost
    private let usage: any UsageRecorder
    private let now: () -> Date
    private let signposter = OSSignposter(subsystem: "app.pounce", category: "search")
    private let logger = Logger(subsystem: "app.pounce", category: "search")

    /// The user's section order: plugin ids, first section first.
    private let sectionOrder: () -> [String]

    init(
        host: PluginHost,
        usage: any UsageRecorder,
        sectionOrder: @escaping () -> [String] = { [] },
        now: @escaping () -> Date = { Date() }
    ) {
        self.host = host
        self.usage = usage
        self.sectionOrder = sectionOrder
        self.now = now
    }

    /// Returns `nil` when the task was cancelled by a newer keystroke.
    func search(_ raw: String) async -> SearchResults? {
        let query = TextNormalizer.query(raw)
        let state = signposter.beginInterval("query")
        defer { signposter.endInterval("query", state) }

        let sources = host.activeSources
        let results = await host.query(query, limit: Self.sourceLimit)
        guard !Task.isCancelled else { return nil }

        var groups: [(pluginID: PluginID, source: any SearchSource, candidates: [Candidate])] = []
        for result in results {
            guard case .results(let candidates) = result.outcome,
                let registered = sources.first(where: {
                    $0.pluginID == result.pluginID && $0.source.id == result.sourceID
                })
            else { continue }
            groups.append((result.pluginID, registered.source, candidates))
        }

        let keys = groups.flatMap { $0.candidates.map(\.itemKey) }
        let stats: [ItemKey: UsageStats]
        do {
            stats = try await usage.stats(for: keys, queryPrefix: Ranker.queryPrefix(query.normalized))
        } catch {
            logger.error("Cannot read usage statistics: \(String(describing: error), privacy: .private)")
            stats = [:]
        }
        guard !Task.isCancelled else { return nil }

        let ranker = Ranker(now: now())
        let statuses = host.activeSearchStatuses.map { PanelStatus(pluginID: $0.pluginID, status: $0.status) }
        if query.isEmpty {
            return SearchResults(
                query: query, sections: recentSection(groups, stats: stats, ranker: ranker), statuses: statuses)
        }

        var sections: [ResultSection] = []
        for entry in SectionOrder.sorted(host.entries, saved: sectionOrder()) {
            let id = entry.manifest.id
            if case .failed = entry.state {
                sections.append(
                    ResultSection(
                        id: "unavailable:\(id.rawValue)",
                        title: entry.manifest.displayName,
                        symbolName: entry.manifest.symbolName,
                        kind: .unavailable(id),
                        items: []
                    )
                )
                continue
            }
            for group in groups where group.pluginID == id {
                let ranked = ranker.rank(group.candidates, stats: stats).prefix(Self.sectionLimit)
                guard !ranked.isEmpty else { continue }
                let sectionID = "\(id.rawValue):\(group.source.id.rawValue)"
                let items = ranked.map {
                    ResultItem(
                        id: "\(sectionID)|\($0.itemKey.rawValue)",
                        candidate: $0,
                        source: group.source,
                        kind: entry.manifest.displayName
                    )
                }
                sections.append(
                    ResultSection(
                        id: sectionID,
                        title: entry.manifest.displayName,
                        symbolName: entry.manifest.symbolName,
                        kind: .results,
                        items: items
                    )
                )
            }
        }
        return SearchResults(query: query, sections: sections, statuses: statuses)
    }

    /// How long a list panel mode's source may take. Generous: the mode shows nothing else meanwhile.
    static let modeBudget: Duration = .seconds(1)
    static let modeLimit = 1000

    /// Searches a list panel mode alone, keeping the source's order. Nothing is ranked here and nothing
    /// touches `UsageRecorder`: a mode's items and queries never reach `ranking.sqlite`. Returns `nil`
    /// when the task was cancelled.
    func search(mode: PanelMode, raw: String, filter: PanelModeFilter.ID?) async -> SearchResults? {
        guard let source = mode.source else { return SearchResults(query: TextNormalizer.query(raw), sections: []) }
        let query = TextNormalizer.query(raw)
        let state = signposter.beginInterval("mode query")
        defer { signposter.endInterval("mode query", state) }
        let adapter = ModeSourceAdapter(
            id: SourceID(rawValue: "mode:\(mode.id.rawValue)"), source: source, filter: filter)
        let outcome = await SourceRunner.runOne(
            adapter, query: query, limit: Self.modeLimit, budget: Self.modeBudget, clock: ContinuousClock())
        guard !Task.isCancelled else { return nil }
        let candidates: [Candidate]
        switch outcome {
        case .results(let found):
            candidates = found
        case .cancelled:
            return nil
        case .failed(let error):
            logger.error("Panel mode source failed: \(String(describing: error), privacy: .private)")
            candidates = []
        case .timedOut:
            logger.notice("Panel mode source exceeded its budget")
            candidates = []
        }
        guard !candidates.isEmpty else { return SearchResults(query: query, sections: []) }
        let sectionID = "mode:\(mode.id.rawValue)"
        var seen = Set<ItemKey>()
        let items = candidates.compactMap { candidate -> ResultItem? in
            guard seen.insert(candidate.itemKey).inserted else { return nil }
            return ResultItem(
                id: "\(sectionID)|\(candidate.itemKey.rawValue)", candidate: candidate, source: adapter,
                kind: mode.title)
        }
        return SearchResults(
            query: query,
            sections: [
                ResultSection(
                    id: sectionID, title: mode.title, symbolName: mode.symbolName, kind: .results, items: items)
            ]
        )
    }

    private func recentSection(
        _ groups: [(pluginID: PluginID, source: any SearchSource, candidates: [Candidate])],
        stats: [ItemKey: UsageStats],
        ranker: Ranker
    ) -> [ResultSection] {
        var sourceByKey: [ItemKey: (any SearchSource, LocalizedStringResource)] = [:]
        var candidates: [Candidate] = []
        for group in groups {
            let kind = host.entries.first { $0.manifest.id == group.pluginID }?.manifest.displayName ?? "Pounce"
            for candidate in group.candidates where sourceByKey[candidate.itemKey] == nil {
                sourceByKey[candidate.itemKey] = (group.source, kind)
                candidates.append(candidate)
            }
        }
        let recent = ranker.recent(candidates, stats: stats, limit: Self.recentLimit)
        guard !recent.isEmpty else { return [] }
        let items = recent.compactMap { candidate -> ResultItem? in
            guard let (source, kind) = sourceByKey[candidate.itemKey] else { return nil }
            return ResultItem(
                id: "recent|\(candidate.itemKey.rawValue)", candidate: candidate, source: source, kind: kind)
        }
        return [
            ResultSection(
                id: "recent",
                title: LocalizedStringResource("Recently Used", comment: "Panel section with recently used items"),
                symbolName: "clock",
                kind: .recent,
                items: items
            )
        ]
    }
}

/// Presents a list panel mode's source, with the selected filter, as a `SearchSource`, so the runner's
/// budget and the panel's action handling apply unchanged.
nonisolated struct ModeSourceAdapter: SearchSource {
    let id: SourceID
    let source: any PanelModeSource
    let filter: PanelModeFilter.ID?

    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        try await source.search(query, filter: filter, limit: limit)
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        source.actions(for: candidate)
    }
}
