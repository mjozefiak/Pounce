import Foundation
import LintelKit
import Synchronization

/// The note sources the library accepted. Notes sees only the sources of active plugins; a second source of one
/// `PluginID` and a source that claims `notes` (the plugin's own manual notes) or no id at all are dropped, so a
/// key has exactly one owner. A dropped source is never asked for anything, so it can neither list nor detach.
struct NoteSourceSet {
    enum Drop: Sendable, Hashable {
        case duplicate(PluginID)
        case invalidID(PluginID)
    }

    private(set) var accepted: [PluginID: any NoteSource] = [:]
    private(set) var order: [PluginID] = []
    private(set) var dropped: [Drop] = []

    init(_ sources: [any NoteSource]) {
        for source in sources {
            let id = source.pluginID
            if id.rawValue.isEmpty || id.rawValue.contains(":") || id == NoteSourceSet.reservedID {
                dropped.append(.invalidID(id))
            } else if accepted[id] != nil {
                dropped.append(.duplicate(id))
            } else {
                accepted[id] = source
                order.append(id)
            }
        }
    }

    /// `true` when both sets hold the same sources in the same order (by identity: a value-type source never
    /// matches, which only costs a restart of the cursors).
    func isSame(as other: NoteSourceSet) -> Bool {
        guard order == other.order, dropped == other.dropped else { return false }
        return order.allSatisfy { id in
            guard let a = accepted[id], let b = other.accepted[id] else { return false }
            return (a as AnyObject) === (b as AnyObject)
        }
    }

    /// The id of Notes itself: manual notes live under it.
    static let reservedID: PluginID = "notes"
}

/// The result of one call to a source under its budget.
enum BudgetedOutcome<Value: Sendable>: Sendable {
    case value(Value)
    /// The source threw. Any error means "unknown", never "gone".
    case failed
    case timedOut
    case cancelled
}

/// Runs one source call against a deadline on the injected clock, the way `SourceRunner` does for search: at the
/// deadline the caller gets its answer and the call is cancelled, without waiting for a source that ignores
/// cancellation.
enum SourceFanOut {
    static let defaultBudget: Duration = .milliseconds(150)

    static func call<Value: Sendable>(
        budget: Duration, clock: any Clock<Duration>, _ operation: @escaping @Sendable () async throws -> Value
    ) async -> BudgetedOutcome<Value> {
        let latch = BudgetLatch<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                latch.install(continuation)
                let work = Task {
                    do {
                        latch.resolve(.value(try await operation()))
                    } catch is CancellationError {
                        latch.resolve(.cancelled)
                    } catch {
                        latch.resolve(.failed)
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

/// Resumes a continuation once with the first outcome, then cancels the rest.
private final class BudgetLatch<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<BudgetedOutcome<Value>, Never>?
        var outcome: BudgetedOutcome<Value>?
        var tasks: [Task<Void, Never>] = []
        var finished = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<BudgetedOutcome<Value>, Never>) {
        let early: BudgetedOutcome<Value>? = state.withLock { state in
            if let outcome = state.outcome {
                state.finished = true
                return outcome
            }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func track(_ task: Task<Void, Never>) {
        let cancelNow = state.withLock { state in
            if state.finished || state.outcome != nil { return true }
            state.tasks.append(task)
            return false
        }
        if cancelNow { task.cancel() }
    }

    func resolve(_ outcome: BudgetedOutcome<Value>) {
        let (continuation, tasks): (CheckedContinuation<BudgetedOutcome<Value>, Never>?, [Task<Void, Never>]) =
            state.withLock { state in
                guard state.outcome == nil else { return (nil, []) }
                state.outcome = outcome
                let continuation = state.continuation
                state.continuation = nil
                if continuation != nil { state.finished = true }
                let tasks = state.tasks
                state.tasks = []
                return (continuation, tasks)
            }
        for task in tasks { task.cancel() }
        continuation?.resume(returning: outcome)
    }
}
