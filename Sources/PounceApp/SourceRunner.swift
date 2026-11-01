import Foundation
import PounceKit
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
        let latch = OutcomeLatch()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                latch.install(continuation)
                let work = Task {
                    do {
                        let candidates = try await source.search(query, limit: limit)
                        latch.resolve(.results(candidates))
                    } catch is CancellationError {
                        latch.resolve(.cancelled)
                    } catch {
                        latch.resolve(.failed(error))
                    }
                }
                let deadline = Task {
                    do {
                        try await clock.sleep(for: budget)
                        latch.resolve(.timedOut)
                    } catch {
                        // Cancelled because the source answered first.
                    }
                }
                latch.track(work)
                latch.track(deadline)
            }
        } onCancel: {
            latch.resolve(.cancelled)
        }
    }
}

/// Resumes a continuation exactly once with the first outcome, then cancels the remaining tasks.
/// Every path (source answer, deadline, outer cancellation) may race; the mutex makes the first one
/// win and the rest no-ops.
private nonisolated final class OutcomeLatch: Sendable {
    private struct State {
        var continuation: CheckedContinuation<SourceOutcome, Never>?
        var outcome: SourceOutcome?
        var tasks: [Task<Void, Never>] = []
        var finished = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<SourceOutcome, Never>) {
        let early: SourceOutcome? = state.withLock { state in
            if let outcome = state.outcome {
                state.finished = true
                return outcome
            }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(returning: early)
        }
    }

    func track(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { state in
            if state.finished || state.outcome != nil {
                return true
            }
            state.tasks.append(task)
            return false
        }
        if cancelNow {
            task.cancel()
        }
    }

    func resolve(_ outcome: SourceOutcome) {
        let (continuation, tasks): (CheckedContinuation<SourceOutcome, Never>?, [Task<Void, Never>]) =
            state.withLock { state in
                guard state.outcome == nil else { return (nil, []) }
                state.outcome = outcome
                let continuation = state.continuation
                state.continuation = nil
                if continuation != nil {
                    state.finished = true
                }
                let tasks = state.tasks
                state.tasks = []
                return (continuation, tasks)
            }
        for task in tasks {
            task.cancel()
        }
        continuation?.resume(returning: outcome)
    }
}
