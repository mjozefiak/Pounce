import Foundation
import LintelCore

/// One suggested app.
struct Suggestion: Hashable, Sendable {
    let record: AppRecord
    /// The frecency decayed to the time of the query.
    let score: Double
    let lastUsedAt: Double
    let isRunning: Bool
}

/// Picks the apps to suggest from the activity snapshot (pure logic, no I/O).
enum SuggestionEngine {
    /// How many apps the empty panel suggests.
    static let limit = 5

    /// The most used apps by decayed frecency, best first; ties go to the most recent use, then the name.
    /// Apps the index does not know (uninstalled), Lintel itself and apps the user hid are skipped.
    static func suggestions(
        snapshot: ActivitySnapshot,
        apps: [AppRecord],
        hidden: Set<String>,
        running: Set<String>,
        ownBundleIdentifier: String?,
        now: Date,
        limit: Int = limit,
        halfLife: TimeInterval = Ranker.frecencyHalfLife
    ) -> [Suggestion] {
        guard !snapshot.isReadOnly, limit > 0, !snapshot.apps.isEmpty else { return [] }
        var byBundleID: [String: AppRecord] = [:]
        for app in apps where byBundleID[app.bundleIdentifier] == nil {
            byBundleID[app.bundleIdentifier] = app
        }
        let candidates = snapshot.apps.compactMap { bundleID, entry -> Suggestion? in
            guard bundleID != ownBundleIdentifier, !hidden.contains(bundleID), let record = byBundleID[bundleID]
            else { return nil }
            return Suggestion(
                record: record,
                score: entry.decayedFrecency(at: now, halfLife: halfLife),
                lastUsedAt: entry.lastUsedAt,
                isRunning: running.contains(bundleID)
            )
        }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            let names = lhs.record.name.localizedStandardCompare(rhs.record.name)
            if names != .orderedSame {
                return names == .orderedAscending
            }
            return lhs.record.bundleIdentifier < rhs.record.bundleIdentifier
        }
        return Array(sorted.prefix(limit))
    }
}
