import Foundation
import LintelCore
import LintelKit
import Synchronization

/// What one search source produced for one query.
nonisolated enum SourceOutcome: Sendable {
    case results([Candidate])
    case failed(any Error)
    /// The source did not answer within its budget; its section is skipped for this query.
    case timedOut
    /// The query was cancelled (a newer keystroke) before the source answered.
    case cancelled
}

nonisolated struct SourceResult: Sendable {
    let pluginID: PluginID
    let sourceID: SourceID
    let outcome: SourceOutcome
}

/// A source together with the plugin that contributed it.
nonisolated struct RegisteredSource: Sendable {
    let pluginID: PluginID
    let source: any SearchSource
}

/// Queries every source independently, each with its own time budget.
///
/// A source that throws, overruns its budget or ignores cancellation loses only its own result: the
/// runner answers for it at the deadline and cancels its task, without waiting for it to return.
nonisolated enum SourceRunner {
    static func run(
        _ sources: [RegisteredSource],
        query: NormalizedQuery,
        limit: Int,
        budget: Duration,
        clock: any Clock<Duration>
    ) async -> [SourceResult] {
        await withTaskGroup(of: (Int, SourceResult).self) { group in
            for (index, registered) in sources.enumerated() {
                group.addTask {
                    let outcome = await runOne(
                        registered.source,
                        query: query,
                        limit: limit,
                        budget: budget,
                        clock: clock
                    )
                    let result = SourceResult(
                        pluginID: registered.pluginID,
                        sourceID: registered.source.id,
                        outcome: outcome
                    )
                    return (index, result)
                }
            }
            var collected: [(Int, SourceResult)] = []
            for await item in group {
                collected.append(item)
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func runOne(
        _ source: any SearchSource,
        query: NormalizedQuery,
        limit: Int,
        budget: Duration,
        clock: any Clock<Duration>
    ) async -> SourceOutcome {
        let work = Task { () -> SourceOutcome in
            do {
                return .results(try await source.search(query, limit: limit))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(error)
            }
        }
        // The deadline is the shared helper; what happens to a source that overran is decided here: it is told to
        // stop, and nobody waits for it to notice.
        guard let outcome = await withDeadline(budget, clock: clock, { await work.value }) else {
            work.cancel()
            return Task.isCancelled ? .cancelled : .timedOut
        }
        return outcome
    }
}
