import Foundation
import LintelKit
import LintelSpeech
import Observation

/// What one document needs for a revise run: its writer (the one head mover), its lock, the store the comments
/// are read from and written to, and which threads to revise (`nil`: every open one).
struct ReviseRequest {
    var item: NoteItemID
    var writer: RevisionWriter
    var lock: EditLock
    var store: NotesStore
    var threads: Set<Int64>?
}

enum ReviseOutcome: Equatable, Sendable {
    struct Applied: Equatable, Sendable {
        var revisionID: Int64
        var blocks: Int
        var threads: Int
        var skipped: [ReviseSkip]
        /// Units the guard left as they were.
        var rejected: Int
    }

    case applied(Applied)
    /// Nothing was asked of the model: every thread was skipped (or there was none left to revise).
    case nothingToRevise(skipped: [ReviseSkip])
    case needsModel
    /// The answer could not be used (the guard rejected it, or it was cut off). Nothing was changed.
    case rejected
    /// The note changed while the agent worked. Nothing was changed.
    case conflict
    case timedOut
    case cancelled
    /// A store, lease or model error. Nothing was changed.
    case failed
    /// The notes model is being removed in Models: no new run starts.
    case modelBeingRemoved
    /// "Ask agent" while a run is active: queued, it runs after the current one.
    case queued
}

/// The revise run (spec "Edit lock and revise run (state machine)", N4, N5): flush, take the lease on the notes
/// model (waiting while it is busy or taken by dictation), lock the editor, generate, check the answer with
/// `ReviseGuard`, and apply it as one `agent` revision through the document's writer with compare-and-set.
///
/// - One run per document; "Ask agent" on a thread is queued while a run is active and runs afterwards.
/// - The timeout (10 minutes) counts only `generating`; `busy` and `yielded` wait and poll ("Waiting for the model").
/// - The result is applied only through `RevisionWriter.appendApplied(expectingHead:)`: if the head moved or text was
///   typed meanwhile, nothing is written (`conflict`). The document is unchanged after a cancel, a timeout, a
///   rejection, a conflict and a failure; quitting cancels (`cancelAll()` from `deactivate()`).
/// - Nothing here logs a prompt, an answer, a note or a comment: codes, counts and durations only.
@MainActor @Observable
final class ReviseService {
    struct Dependencies {
        var clock: RunClock
        /// The notes model and its lease, or `nil` when none is installed.
        var model: @Sendable () async -> ResolvedReviseModel?
        var log: any NotesLogging = OSNotesLog()
        /// How often a run asks again while the model is busy.
        var busyPoll: Duration = .seconds(5)
        /// How many times dictation may take the model from one run before it gives up.
        var maxYields = 20
        var now: @Sendable () -> Date = { Date() }
    }

    private let deps: Dependencies
    @ObservationIgnored private var runs: [NoteItemID: Task<ReviseOutcome, Never>] = [:]
    @ObservationIgnored private var queued: [NoteItemID: Set<Int64>?] = [:]
    private var reservations = 0

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// A run is going on in any document, at any of its phases (also while it waits for the model or between a
    /// yield and the next lease): the Models pane must not remove the file.
    var isRunActive: Bool { !runs.isEmpty }

    func isRunning(_ item: NoteItemID) -> Bool { runs[item] != nil }

    func isQueued(_ item: NoteItemID, thread: Int64) -> Bool {
        guard let waiting = queued[item] else { return false }
        return waiting?.contains(thread) ?? true
    }

    /// Models → Remove: while the file is being removed no run starts. Call the result when removal is over.
    func reserveRemoval() -> @MainActor @Sendable () -> Void {
        reservations += 1
        return { [weak self] in self?.reservations -= 1 }
    }

    /// Runs the request and returns how it ended; with a run already active in the document the request is queued
    /// and `.queued` returns at once.
    func start(_ request: ReviseRequest) async -> ReviseOutcome {
        if runs[request.item] != nil {
            merge(request.threads, into: request.item)
            return .queued
        }
        guard reservations == 0 else { return .modelBeingRemoved }
        var next = request
        while true {
            let current = next
            let item = request.item
            let task = Task { () -> ReviseOutcome in
                let outcome = await self.perform(current)
                self.runs[item] = nil
                return outcome
            }
            runs[item] = task
            let outcome = await task.value
            runs[request.item] = nil
            // Whatever was asked while it ran goes next; a cancel, a missing model or an error drops it.
            guard let waiting = queued.removeValue(forKey: request.item) else { return outcome }
            switch outcome {
            case .applied, .nothingToRevise, .conflict, .rejected:
                guard reservations == 0 else { return outcome }
                next.threads = waiting
            default:
                return outcome
            }
        }
    }

    private func merge(_ threads: Set<Int64>?, into item: NoteItemID) {
        if let existing = queued[item] {
            if let existing, let threads { queued[item] = existing.union(threads) } else { queued[item] = .some(nil) }
        } else {
            queued[item] = .some(threads)
        }
    }

    /// The user's Cancel: stops the run between two tokens; the document is unchanged.
    func cancel(_ item: NoteItemID) {
        queued[item] = nil
        runs[item]?.cancel()
    }

    /// Quit and `deactivate()`: every run is cancelled and awaited, so no half revision exists afterwards.
    func cancelAll() async {
        queued = [:]
        let all = Array(runs.values)
        for task in all { task.cancel() }
        for task in all { _ = await task.value }
    }

    // MARK: Run

    @MainActor private final class Held {
        var handle: (any ReviseModelHandle)?

        func release() async {
            let taken = handle
            handle = nil
            await taken?.release()
        }
    }

    private func perform(_ request: ReviseRequest) async -> ReviseOutcome {
        let lock = request.lock
        let clock = deps.clock
        guard lock.move(to: .flushing, at: clock.now()) else { return .failed }
        let held = Held()
        let started = clock.now()
        var outcome: ReviseOutcome
        do {
            outcome = try await execute(request, held)
        } catch is CancellationError {
            outcome = end(lock, .cancelled, .cancelled)
        } catch {
            outcome = end(lock, .failed, .failed)
        }
        await held.release()
        let milliseconds = Int((clock.now() - started) / .milliseconds(1))
        deps.log.notice(
            NotesLogEvent(
                "revise", code: Self.code(outcome), count: Self.count(outcome), durationMs: milliseconds,
                key: request.item.key.rawValue))
        return outcome
    }

    private func end(_ lock: EditLock, _ phase: EditLock.Phase, _ outcome: ReviseOutcome) -> ReviseOutcome {
        if !lock.move(to: phase, at: deps.clock.now()) { lock.move(to: .failed, at: deps.clock.now()) }
        return outcome
    }

    private func complete(_ lock: EditLock, _ outcome: ReviseOutcome) -> ReviseOutcome {
        lock.move(to: .idle, at: deps.clock.now())
        return outcome
    }

    private func execute(_ request: ReviseRequest, _ held: Held) async throws -> ReviseOutcome {
        let lock = request.lock
        let clock = deps.clock
        // flushing: typed text is written and the document exists before anything else happens.
        var head = try await request.writer.ensureDocument()
        try Task.checkCancellation()
        var threads = try await Self.threads(of: head.docID, in: request.store, only: request.threads)
        let first = ReviseUnitPlanner.plan(head: head.body, threads: threads)
        if first.units.isEmpty { return complete(lock, .nothingToRevise(skipped: first.skipped)) }
        guard let model = await deps.model() else { return complete(lock, .needsModel) }
        try Task.checkCancellation()

        lock.move(to: .waitingForModel, at: clock.now())
        var yields = 0
        while true {
            try Task.checkCancellation()
            do {
                held.handle = try await model.leasing.acquire()
            } catch ModelLeaseError.busy {
                // Another model file (or dictation's grace period) holds the memory: "Waiting for the model".
                try await deps.clock.sleep(deps.busyPoll)
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return end(lock, .failed, .failed)
            }
            guard let handle = held.handle else { return end(lock, .failed, .failed) }

            // In one main-actor step: flush, capture the head, enter `generating`. Text typed while the lease was
            // being taken (the editor is still editable) is written first, and the plan is made on what was saved.
            repeat {
                head = try await request.writer.ensureDocument()
                threads = try await Self.threads(of: head.docID, in: request.store, only: request.threads)
                try Task.checkCancellation()
            } while request.writer.hasPendingText
            let plan = ReviseUnitPlanner.plan(head: head.body, threads: threads)
            if plan.units.isEmpty { return complete(lock, .nothingToRevise(skipped: plan.skipped)) }
            lock.move(to: .generating, at: clock.now())

            let messages = ReviseNotesPrompt.messages(units: plan.units)
            let maxTokens = ReviseNotesPrompt.maxTokens(units: plan.units, contextLength: ReviseModelKey.contextLength)
            let answer: GenerationResult
            do {
                switch try await race(handle, messages, maxTokens, remaining: lock.remaining(at: clock.now())) {
                case .result(let result): answer = result
                case .timedOut: return end(lock, .timedOut, .timedOut)
                }
            } catch ModelLeaseError.yielded {
                // Dictation took the model: the lease is gone, the editor is editable again, and the run waits.
                await held.release()
                yields += 1
                if yields > deps.maxYields { return end(lock, .failed, .failed) }
                lock.move(to: .waitingForModel, at: clock.now())
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return end(lock, .failed, .failed)
            }
            return try await finish(request, head: head, plan: plan, threads: threads, answer: answer, model: model)
        }
    }

    private enum Raced {
        case result(GenerationResult)
        case timedOut
    }

    /// The generation against the time that is left of the generating limit.
    private func race(
        _ handle: any ReviseModelHandle, _ messages: [ChatMessage], _ maxTokens: Int, remaining: Duration
    ) async throws -> Raced {
        let sleep = deps.clock.sleep
        return try await withThrowingTaskGroup(of: Raced.self) { group in
            group.addTask { .result(try await handle.generate(messages: messages, maxTokens: maxTokens)) }
            group.addTask {
                try await sleep(remaining)
                return .timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    private func finish(
        _ request: ReviseRequest, head: RevisionWriter.Head, plan: RevisePlan, threads: [CommentThread],
        answer: GenerationResult, model: ResolvedReviseModel
    ) async throws -> ReviseOutcome {
        let lock = request.lock
        lock.move(to: .validating, at: deps.clock.now())
        // An answer cut off by the token limit is never used.
        if answer.stoppedByTokenLimit { return end(lock, .rejected, .rejected) }
        let verdict: ReviseGuard.Verdict
        do {
            verdict = try ReviseGuard.check(head: head.body, plan: plan, answer: answer.text)
        } catch {
            return end(lock, .rejected, .rejected)
        }
        if verdict.applied.isEmpty {
            return verdict.rejected.isEmpty
                ? complete(lock, .nothingToRevise(skipped: verdict.skipped)) : end(lock, .rejected, .rejected)
        }
        try Task.checkCancellation()

        // The write below is one transaction and is not interrupted by a cancel.
        lock.move(to: .applying, at: deps.clock.now())
        let appliedIDs = Set(verdict.applied.flatMap(\.threadIDs))
        let rootIDs = threads.filter { appliedIDs.contains($0.id) }.map(\.root.id).sorted()
        let blocks = verdict.changedBlockCount
        let meta = NoteMeta.json([
            "model": model.id, "prompt_version": ReviseNotesPrompt.version, "comment_ids": rootIDs,
            "base_head_id": head.revisionID,
        ])
        let revisionID: Int64
        do {
            revisionID = try await request.writer.appendApplied(
                author: .agent, body: verdict.body,
                summary: String(
                    localized: "Revised \(blocks) blocks from comments",
                    comment: "History: the summary of a revision the agent wrote from comments"),
                metaJSON: meta, expectingHead: head.revisionID)
        } catch NotesError.casConflict {
            return end(lock, .conflict, .conflict)
        } catch {
            return end(lock, .failed, .failed)
        }
        await Self.resolve(appliedIDs, docID: head.docID, store: request.store, now: deps.now())
        lock.move(to: .idle, at: deps.clock.now())
        return .applied(
            ReviseOutcome.Applied(
                revisionID: revisionID, blocks: blocks, threads: appliedIDs.count, skipped: verdict.skipped,
                rejected: verdict.rejected.count))
    }

    // MARK: Store

    private static func threads(of docID: Int64, in store: NotesStore, only: Set<Int64>?) async throws
        -> [CommentThread]
    {
        try await Task.detached {
            let all = CommentThreads.group(try store.comments(of: docID))
            guard let only else { return all }
            return all.filter { only.contains($0.id) }
        }.value
    }

    /// The agent answers each revised thread with a short "Revised" and resolves it.
    private static func resolve(_ threadIDs: Set<Int64>, docID: Int64, store: NotesStore, now: Date) async {
        await Task.detached {
            for id in threadIDs.sorted() {
                _ = try? store.addReply(
                    docID: docID, threadID: id, author: NoteAuthor.agent.rawValue,
                    body: String(localized: "Revised", comment: "Comments: the agent's reply on a thread it revised"),
                    now: now)
                _ = try? store.setThreadStatus(docID: docID, threadID: id, status: .resolved, now: now)
            }
        }.value
    }

    // MARK: Log

    private static func code(_ outcome: ReviseOutcome) -> String {
        switch outcome {
        case .applied: "applied"
        case .nothingToRevise: "nothingToRevise"
        case .needsModel: "needsModel"
        case .rejected: "rejected"
        case .conflict: "casConflict"
        case .timedOut: "timedOut"
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .modelBeingRemoved: "modelBeingRemoved"
        case .queued: "queued"
        }
    }

    private static func count(_ outcome: ReviseOutcome) -> Int? {
        if case .applied(let applied) = outcome { applied.blocks } else { nil }
    }
}
