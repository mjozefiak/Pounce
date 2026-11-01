import Foundation
import PounceCore
import PounceKit
import Synchronization

/// One app with its searchable names prepared once, when the index is published.
struct IndexedApp: Sendable {
    let record: AppRecord
    let itemKey: ItemKey
    /// The display name first, then the aliases.
    let names: [NormalizedText]

    init(_ record: AppRecord) {
        self.record = record
        self.itemKey = ItemKey(pluginID: AppsPlugin.manifest.id, key: record.bundleIdentifier)
        self.names = ([record.name] + record.aliases).map(NormalizedText.init)
    }
}

/// The published app list. Searches read the current snapshot without waiting for a scan; a new scan
/// replaces it in one step.
final class AppStore: Sendable {
    private let state = Mutex<[IndexedApp]>([])

    var apps: [IndexedApp] { state.withLock { $0 } }

    func publish(_ records: [AppRecord]) {
        let indexed = records.map(IndexedApp.init)
        state.withLock { $0 = indexed }
    }

    func app(for key: ItemKey) -> IndexedApp? {
        guard key.pluginID == AppsPlugin.manifest.id else { return nil }
        return apps.first { $0.record.bundleIdentifier == key.key }
    }
}

/// Searches the app list by display name and aliases.
struct AppSearchSource: SearchSource {
    let id: SourceID = "apps.applications"
    let store: AppStore
    let usage: any UsageRecorder
    let workspace: any WorkspaceClient
    let clock: @Sendable () -> Date

    init(
        store: AppStore,
        usage: any UsageRecorder,
        workspace: any WorkspaceClient,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.usage = usage
        self.workspace = workspace
        self.clock = clock
    }

    /// An empty query returns the apps with recorded uses, which the shell ranks by frecency; any
    /// other query returns the best matches of every app's names, best tier first.
    func search(_ query: NormalizedQuery, limit: Int) async throws -> [Candidate] {
        let apps = store.apps
        guard !query.isEmpty else {
            let keys = try await usage.mostUsed(pluginID: AppsPlugin.manifest.id, limit: limit, now: clock())
            return keys.compactMap { key in
                store.app(for: key).map { candidate($0, MatchResult(tier: .exact, score: 0)) }
            }
        }

        let scalars = Array(query.normalized.unicodeScalars)
        var candidates: [Candidate] = []
        for (index, app) in apps.enumerated() {
            if index % 128 == 0 {
                try Task.checkCancellation()
            }
            if let match = Self.bestMatch(scalars, app) {
                candidates.append(candidate(app, match))
            }
        }
        candidates.sort { lhs, rhs in
            if lhs.match.tier != rhs.match.tier {
                return lhs.match.tier < rhs.match.tier
            }
            if lhs.match.score != rhs.match.score {
                return lhs.match.score > rhs.match.score
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return Array(candidates.prefix(limit))
    }

    /// The best match over the display name and aliases. A match on an alias keeps its tier but loses a
    /// little score and has no highlight, because the alias is not what the row shows.
    static func bestMatch(_ query: [Unicode.Scalar], _ app: IndexedApp) -> MatchResult? {
        var best: MatchResult?
        for (index, name) in app.names.enumerated() {
            guard var match = FuzzyMatcher.match(query, in: name) else { continue }
            if index > 0 {
                match = MatchResult(tier: match.tier, score: match.score * 0.95)
            }
            if let current = best,
                current.tier < match.tier || (current.tier == match.tier && current.score >= match.score)
            {
                continue
            }
            best = match
        }
        return best
    }

    private func candidate(_ app: IndexedApp, _ match: MatchResult) -> Candidate {
        Candidate(itemKey: app.itemKey, title: app.record.name, icon: .file(app.record.url), match: match)
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        guard let app = store.app(for: candidate.itemKey) else { return [] }
        return AppActions(record: app.record, itemKey: app.itemKey, usage: usage, workspace: workspace, clock: clock)
            .all
    }
}
