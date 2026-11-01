import Foundation
import PounceCore
import PounceKit

/// The clipboard mode's results (spec step 2.4).
///
/// An empty query lists entries by `last_used_at`, newest first. A query is matched fuzzily against
/// the titles of the 1000 most recent entries plus the top 200 full-text (FTS5) hits, then ranked by
/// match tier and, within a tier, by frecency from `use_count` and `last_used_at`. These two columns
/// are the clipboard's only frecency signal: nothing here reads or writes `ranking.sqlite`.
struct ClipboardSearchSource: PanelModeSource {
    static let recentWindow = 1000
    static let fullTextLimit = 200

    let shared: ClipboardShared
    let paste: @Sendable (Int64, ActionContext) async throws -> Void
    let copy: @Sendable (Int64, ActionContext) async throws -> Void
    let delete: @Sendable (Int64) async throws -> Void
    var now: @Sendable () -> Date = { Date() }

    func search(_ query: NormalizedQuery, filter: PanelModeFilter.ID?, limit: Int) async throws -> [Candidate] {
        guard let store = shared.current else { return [] }
        let kind = filter.flatMap(ClipKind.init(rawValue:))
        let now = now()
        try Task.checkCancellation()
        if query.isEmpty {
            return try store.recent(limit: limit, kind: kind).map { candidate($0, match: nil, now: now) }
        }

        var summaries = try store.recent(limit: Self.recentWindow, kind: kind)
        var seen = Set(summaries.map(\.id))
        try Task.checkCancellation()
        let hits = try store.search(query.raw, limit: Self.fullTextLimit, kind: kind)
        for hit in hits where seen.insert(hit.id).inserted {
            summaries.append(hit)
        }
        let fullText = Set(hits.map(\.id))
        try Task.checkCancellation()

        var candidates: [Candidate] = []
        var stats: [ItemKey: UsageStats] = [:]
        for (index, summary) in summaries.enumerated() {
            if index % 200 == 0 {
                try Task.checkCancellation()
            }
            let title = ClipPresentation.title(summary)
            let match =
                FuzzyMatcher.match(query, in: TextNormalizer.prepare(title))
                ?? (fullText.contains(summary.id) ? MatchResult(tier: .fuzzy, score: 0) : nil)
            guard let match else { continue }
            let candidate = candidate(summary, match: match, now: now)
            candidates.append(candidate)
            stats[candidate.itemKey] = UsageStats(
                frecency: Double(summary.useCount),
                lastUsedAt: summary.lastUsedAt,
                useCount: summary.useCount,
                queryAssociationCount: 0
            )
        }
        return Array(Ranker(now: now).rank(candidates, stats: stats).prefix(limit))
    }

    func actions(for candidate: Candidate) -> [ResultAction] {
        guard let id = ClipPresentation.entryID(candidate.itemKey) else { return [] }
        let paste = paste
        let copy = copy
        let delete = delete
        let first =
            shared.pasteAllowed
            ? ResultAction(
                id: "clipboard.paste",
                title: LocalizedStringResource("Paste", comment: "Clipboard action that pastes into the previous app"),
                symbolName: "doc.on.clipboard"
            ) { context in try await paste(id, context) }
            : ResultAction(
                id: "clipboard.paste",
                title: LocalizedStringResource("Copy", comment: "Clipboard action that copies the entry"),
                symbolName: "doc.on.doc"
            ) { context in try await paste(id, context) }
        return [
            first,
            ResultAction(
                id: "clipboard.copy",
                title: LocalizedStringResource("Copy Only", comment: "Clipboard action that copies without pasting"),
                symbolName: "doc.on.doc",
                shortcut: KeyShortcut(key: "\r", modifiers: .command)
            ) { context in try await copy(id, context) },
            ResultAction(
                id: "clipboard.delete",
                title: LocalizedStringResource("Delete", comment: "Clipboard action that deletes the entry"),
                symbolName: "trash",
                shortcut: KeyShortcut(key: "x", modifiers: .control),
                keepsPanelOpen: true
            ) { _ in try await delete(id) },
        ]
    }

    /// Recency breaks ties within a tier: a fresher entry gets a small boost.
    private func candidate(_ summary: ClipSummary, match: MatchResult?, now: Date) -> Candidate {
        let age = max(0, now.timeIntervalSince(summary.lastUsedAt)) / 86_400
        return Candidate(
            itemKey: ClipPresentation.itemKey(summary.id),
            title: ClipPresentation.title(summary),
            subtitle: ClipPresentation.subtitle(summary, now: now),
            icon: ClipPresentation.icon(summary),
            match: match ?? MatchResult(tier: .exact, score: 0),
            boost: 1 / (1 + age)
        )
    }
}
