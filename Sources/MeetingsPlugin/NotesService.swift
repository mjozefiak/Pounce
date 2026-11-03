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

        /// "Pobierz model notatek" is offered.
        var needsModel: Bool { enabled && modelMissing }
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
///   priority (dictation always goes first, and a different model in use makes the job wait: "Czeka na model").
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
    /// has put its status back when this returns.
    func shutDown() async {
        accepting = false
        queue = []
        sampleTask?.cancel()
        worker?.cancel()
        await worker?.value
        _ = await sampleTask?.value
        worker = nil
        sampleTask = nil
        board.update { $0.phases = [:] }
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
        guard accepting, current?.meetingID != job.meetingID, !queue.contains(where: { $0.meetingID == job.meetingID })
        else { return }
        queue.append(job)
        setPhase(.queued, for: job.meetingID)
        if worker == nil { worker = Task { await self.drain() } }
    }

    private func drain() async {
        while !Task.isCancelled, !queue.isEmpty {
            let job = queue.removeFirst()
            current = job
            await process(job)
            current = nil
            board.update { $0.phases[job.meetingID] = nil }
            deps.changed()
        }
        worker = nil
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
            if board.update({ $0.modelMissing = true }) { deps.changed() }
            if job.requested { deps.openSettings() }
            return
        }
        board.update { $0.modelMissing = false }
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
        conclude(outcome, job: job, previous: previous, model: model, store: store)
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

    private func conclude(
        _ outcome: Result<NotesResult, any Error>, job: Job, previous: NotesStatus, model: LLMModel,
        store: MeetingsStore
    ) {
        let id = job.meetingID
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
            } else {
                let written =
                    (try? store.finishNotes(
                        id, markdown: result.markdown, status: status, promptVersion: result.promptVersion,
                        model: model.id, droppedCount: result.droppedCount, generatedAt: deps.now())) ?? false
                if !written { logger.notice("Notes finished after the meeting changed; they were not stored") }
            }
            logger.notice(
                "Notes \(String(describing: result.status), privacy: .public): \(result.chunkCount, privacy: .public) chunks, \(result.verifiedPointCount, privacy: .public) points, \(result.droppedCount, privacy: .public) dropped"
            )
        }
        deps.library.refreshCount()
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
