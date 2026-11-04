import Foundation
import PounceSpeech
import Synchronization
import os

/// What a notes job is doing right now. In memory only: the database has `running`, this says more.
enum NotesJobPhase: Equatable, Sendable {
    /// Waiting for its turn (one notes job runs at a time).
    case queued
    /// Another model (dictation's, for example) holds the memory ("Czeka na model").
    case waitingForModel
    case mapping(done: Int, total: Int)
    case reducing
}

/// What the library list, its actions and the meeting windows may read from any thread: whether notes are on,
/// whether their model is missing, and what each running job does. Written by `NotesService` on the main actor.
final class NotesBoard: Sendable {
    struct Snapshot: Equatable, Sendable {
        var enabled = false
        /// Notes are wanted but the chosen model is not downloaded.
        var modelMissing = false
        var phases: [Int64: NotesJobPhase] = [:]
        /// Meetings that became `ready` in this session while notes were on and the model was missing. Only they
        /// show "Notes model needed": older meetings and meetings recorded while notes were off show nothing,
        /// and nothing is written for them when the model arrives ("Regenerate" does it on request). In memory:
        /// a restart forgets the badge.
        var awaitingModel: Set<Int64> = []

        /// Notes are wanted and their model is missing.
        var needsModel: Bool { enabled && modelMissing }

        /// "Pobierz model notatek" is offered for this meeting.
        func needsModel(for meetingID: Int64) -> Bool { needsModel && awaitingModel.contains(meetingID) }
    }

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func phase(of meetingID: Int64) -> NotesJobPhase? { state.withLock { $0.phases[meetingID] } }

    /// Applies `change`; true when the snapshot differs afterwards.
    @discardableResult
    func update(_ change: (inout Snapshot) -> Void) -> Bool {
        state.withLock { snapshot in
            let before = snapshot
            change(&snapshot)
            return before != snapshot
        }
    }
}

/// The result of "Try it" (nothing is stored).
enum NotesSampleOutcome: Equatable, Sendable {
    case notes(String)
    case modelMissing
    case failed
}

/// Writes the notes of finished meetings in the background (spec: Proposed Solution, step 4, and Phase 2).
///
/// - After a meeting becomes `ready` and only when `notesEnabled` was switched on by the user, the meeting is
///   queued; "Regenerate" queues it whatever the switch says (the user asked). One job runs at a time.
/// - A job loads nothing itself: it asks `NotesPipeline`, which takes the shared `LLMLease` at `background`
///   priority (dictation always goes first, also on the same model file at another context length: the notes'
///   lease is taken away and they continue after dictation; a different model file in use makes the job wait:
///   "Czeka na model").
/// - `notes_status` goes `none`/`ok`/`partial`/`failed`/`stale` → `running` → `ok`/`partial`/`failed`. The
///   transcript is never written. A cancelled job (the plugin is switched off, the app quits) puts the status
///   back as it was and writes nothing else; the one documented partial result is the pipeline's own `partial`.
/// - The model must be downloaded already; nothing is fetched here. A missing model leaves the notes as they
///   were and the board says so (the library offers "Download Notes Model").
/// - A crash while `running` is settled at the next open (`NotesRecovery`).
///
/// The transcript and the notes never reach a log: only counts and statuses do.
@MainActor
final class NotesService {
    struct Dependencies {
        var library: MeetingsLibrary
        var settings: MeetingsSettings
        var lease: LLMLease = .shared
        /// The installed file of a catalog model, or `nil` when it is not downloaded.
        var modelFile: @Sendable (LLMModel) async -> URL?
        var makeRuntime: @Sendable () -> any LLMRuntime = { LlamaRuntime(contextLength: NotesModel.contextLength) }
        /// Tests shorten the timeouts and the waiting for a busy model.
        var configure: @Sendable (inout NotesPipeline.Configuration) -> Void = { _ in }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
        var now: @Sendable () -> Date = { Date() }
        /// How long `shutDown` waits for a job that does not stop (a model load cannot be cancelled).
        var shutdownLimit: Duration = .seconds(5)
        var openSettings: @MainActor () -> Void = {}
        var changed: @Sendable () -> Void = {}
        var logger = Logger(subsystem: "app.pounce", category: "meetings")
    }

    private struct Job: Equatable {
        var meetingID: Int64
        /// Started by the user ("Regenerate"): runs even when automatic notes are off, and opens Settings when
        /// the model is missing.
        var requested: Bool
    }

    let board = NotesBoard()

    private let deps: Dependencies
    private var queue: [Job] = []
    private var current: Job?
    private var worker: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?
    /// Meetings whose notes must be written again right after the running job (a regenerate request, or a rename
    /// that made the finished notes `stale`).
    private var rerun: Set<Int64> = []
    /// Bumped by `shutDown`: a job that did not stop in time must not touch the state of a later start.
    private var epoch = 0
    private var sampleTask: Task<NotesSampleOutcome, Never>?
    private var accepting = false

    init(_ dependencies: Dependencies) {
        deps = dependencies
    }

    // MARK: Lifecycle

    /// The plugin is active: jobs are accepted.
    func start() async {
        accepting = true
        await refreshAvailability()
    }

    /// The plugin is switched off or the app quits: queued jobs are dropped, the running one is cancelled and
    /// has put its status back when this returns. A job that does not stop within `shutdownLimit` (a model
    /// load cannot be cancelled) is left to finish by itself: it finds the library closed and writes nothing,
    /// and the status it left `running` becomes `failed` at the next open (`NotesRecovery`).
    func shutDown() async {
        accepting = false
        queue = []
        rerun = []
        epoch += 1
        sampleTask?.cancel()
        jobTask?.cancel()
        worker?.cancel()
        let worker = worker
        let sampleTask = sampleTask
        _ = await Self.within(deps.shutdownLimit, sleep: deps.sleep) {
            await worker?.value
            _ = await sampleTask?.value
        }
        self.worker = nil
        self.sampleTask = nil
        jobTask = nil
        current = nil
        board.update {
            $0.phases = [:]
            $0.awaitingModel = []
        }
    }

    /// The library is closing or erased: the queue is dropped and the running job is cancelled, but the service
    /// keeps accepting jobs (the plugin may stay on after "Erase Data").
    func cancelJobs() {
        let dropped = queue.map(\.meetingID)
        queue = []
        if !dropped.isEmpty {
            board.update { for id in dropped { $0.phases[id] = nil } }
            deps.changed()
        }
        rerun = []
        jobTask?.cancel()
        sampleTask?.cancel()
    }

    /// True when `operation` finished within `limit`; false when the limit came first (the operation is
    /// not waited for).
    private static func within(
        _ limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ operation: @escaping @Sendable () async -> Void
    ) async -> Bool {
        let outcome: ()? = try? await NotesDeadline.run(limit: limit, sleep: sleep) { phase in
            phase(.running)
            await operation()
        }
        return outcome != nil
    }

    /// Whether any job is queued or running (the model's file is in use then).
    var isBusy: Bool { current != nil || !queue.isEmpty || sampleTask != nil }

    /// Re-reads the notes switch and whether the chosen model is downloaded (Settings calls it after a
    /// download, a removal or a change of the switch or the model).
    func refreshAvailability() async {
        let enabled = deps.settings.notesEnabled
        let installed = await deps.modelFile(deps.settings.builtInLLMModel) != nil
        let changed = board.update {
            $0.enabled = enabled
            $0.modelMissing = !installed
        }
        if changed { deps.changed() }
    }

    // MARK: Requests

    /// A meeting just became `ready`.
    func meetingBecameReady(_ id: Int64) {
        guard deps.settings.notesEnabled else { return }
        enqueue(Job(meetingID: id, requested: false))
    }

    /// "Regeneruj notatki" (⌘R, the button of the meeting window); also for stale and failed notes.
    func regenerate(_ id: Int64) {
        enqueue(Job(meetingID: id, requested: true))
    }

    private func enqueue(_ job: Job) {
        guard accepting else { return }
        if current?.meetingID == job.meetingID {
            // The user asked while the job runs: it is not a no-op, the notes are written again right after.
            if job.requested { rerun.insert(job.meetingID) }
            return
        }
        guard !queue.contains(where: { $0.meetingID == job.meetingID }) else { return }
        queue.append(job)
        setPhase(.queued, for: job.meetingID)
        if worker == nil { worker = Task { await self.drain() } }
    }

    private func drain() async {
        let epoch = epoch
        while !Task.isCancelled, epoch == self.epoch, !queue.isEmpty {
            let job = queue.removeFirst()
            current = job
            let task = Task { await self.process(job) }
            jobTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
            guard epoch == self.epoch else { return }
            jobTask = nil
            current = nil
            board.update { $0.phases[job.meetingID] = nil }
            deps.changed()
            if rerun.remove(job.meetingID) != nil { enqueue(Job(meetingID: job.meetingID, requested: true)) }
        }
        if epoch == self.epoch { worker = nil }
    }

    private func setPhase(_ phase: NotesJobPhase, for id: Int64) {
        if board.update({ $0.phases[id] = phase }) { deps.changed() }
    }

    // MARK: One job

    private func process(_ job: Job) async {
        let id = job.meetingID
        guard let store = deps.library.store else { return }
        if !job.requested, !deps.settings.notesEnabled { return }
        guard let document = try? await MeetingLibraryIO.document(store: store, id: id), document.status == .ready
        else { return }
        let utterances = NotesUtterance.make(from: document)
        guard !utterances.isEmpty else { return }

        let model = deps.settings.builtInLLMModel
        guard let file = await deps.modelFile(model) else {
            // Nothing is written: the notes stay as they were, and the library offers the download.
            if board.update({
                $0.modelMissing = true
                if !job.requested { $0.awaitingModel.insert(id) }
            }) {
                deps.changed()
            }
            if job.requested { deps.openSettings() }
            return
        }
        board.update {
            $0.modelMissing = false
            $0.awaitingModel = []
        }
        guard let previous = try? store.beginNotes(id) else { return }
        setPhase(.queued, for: id)

        var configuration = NotesPipeline.Configuration()
        configuration.chunkTokens = deps.settings.notesChunkTokens
        configuration.reduceInputTokens = deps.settings.notesReduceInputTokens
        deps.configure(&configuration)
        let pipeline = NotesPipeline(
            model: NotesModel(lease: deps.lease, runtime: deps.makeRuntime(), modelURL: file),
            configuration: configuration, sleep: deps.sleep)

        let outcome: Result<NotesResult, any Error>
        do {
            outcome = .success(
                try await pipeline.run(utterances: utterances) { [weak self] event in
                    Task { @MainActor in self?.apply(event, to: id) }
                })
        } catch {
            outcome = .failure(error)
        }
        let epoch = epoch
        if conclude(outcome, job: job, previous: previous, model: model, store: store), epoch == self.epoch {
            rerun.insert(id)
        }
    }

    private func apply(_ event: NotesEvent, to id: Int64) {
        // A late event of a finished job must not bring its phase back.
        guard current?.meetingID == id else { return }
        switch event {
        case .waitingForModel: setPhase(.waitingForModel, for: id)
        case .map(let done, let total): setPhase(.mapping(done: done, total: total), for: id)
        case .reduce, .finishing: setPhase(.reducing, for: id)
        }
    }

    /// Writes what the job ended with. True when the notes were stored `stale` (a rename came while they were
    /// written) and must be written again.
    private func conclude(
        _ outcome: Result<NotesResult, any Error>, job: Job, previous: NotesStatus, model: LLMModel,
        store: MeetingsStore
    ) -> Bool {
        let id = job.meetingID
        var again = false
        let logger = deps.logger
        switch outcome {
        case .failure(let error):
            if error is CancellationError {
                // Back to what it was; nothing partial is kept.
                _ = try? store.settleNotes(id, status: previous)
                logger.notice("Notes cancelled")
            } else {
                _ = try? store.settleNotes(id, status: .failed)
                logger.error("Notes failed: \(String(describing: error), privacy: .public)")
            }
        case .success(let result):
            let status: NotesStatus
            switch result.status {
            case .ok: status = .ok
            case .partial: status = .partial
            case .failed: status = .failed
            }
            if status == .failed || result.markdown == nil {
                _ = try? store.settleNotes(id, status: status == .failed ? .failed : previous)
            } else if status == .partial, previous == .ok {
                // A worse result never replaces complete notes: they stay, and the status says the new run failed
                // ("Writing the notes failed. The notes below are from an earlier run.").
                _ = try? store.settleNotes(id, status: .failed)
                logger.notice("Partial notes were not stored over complete ones")
            } else {
                let outcome =
                    (try? store.finishNotes(
                        id, markdown: result.markdown, status: status, promptVersion: result.promptVersion,
                        model: model.id, droppedCount: result.droppedCount, generatedAt: deps.now())) ?? .discarded
                switch outcome {
                case .stored: break
                case .storedStale:
                    // A speaker was renamed while the notes were written: write them again with the new names.
                    again = true
                    logger.notice("Notes finished after a rename; they are written again")
                case .discarded: logger.notice("Notes finished after the meeting changed; they were not stored")
                }
            }
            logger.notice(
                "Notes \(String(describing: result.status), privacy: .public): \(result.chunkCount, privacy: .public) chunks, \(result.verifiedPointCount, privacy: .public) points, \(result.droppedCount, privacy: .public) dropped"
            )
        }
        deps.library.refreshCount()
        return again
    }

    // MARK: Try it

    /// "Wypróbuj na przykładzie": the pipeline on the bundled sample, nothing stored.
    func runSample() -> Task<NotesSampleOutcome, Never> {
        if let sampleTask { return sampleTask }
        let task = Task { [weak self] () -> NotesSampleOutcome in
            guard let self else { return .failed }
            let outcome = await self.sample()
            self.sampleTask = nil
            return outcome
        }
        sampleTask = task
        return task
    }

    private func sample() async -> NotesSampleOutcome {
        guard let file = await deps.modelFile(deps.settings.builtInLLMModel) else { return .modelMissing }
        var configuration = NotesPipeline.Configuration()
        configuration.chunkTokens = deps.settings.notesChunkTokens
        configuration.reduceInputTokens = deps.settings.notesReduceInputTokens
        deps.configure(&configuration)
        let pipeline = NotesPipeline(
            model: NotesModel(lease: deps.lease, runtime: deps.makeRuntime(), modelURL: file),
            configuration: configuration, sleep: deps.sleep)
        do {
            let result = try await pipeline.run(utterances: NotesSample.utterances)
            if let markdown = result.markdown, result.status != .failed { return .notes(markdown) }
            return .failed
        } catch {
            return .failed
        }
    }
}
