import Foundation
import LintelSpeech
import Synchronization

/// The built-in model the notes run on: the shared `LLMLease` (key: model file, context length 8192), the
/// runtime that loads the file when nobody else did, and the keep-warm time after the last release.
struct NotesModel: Sendable {
    /// The longest prompt plus answer of the notes (spec: kontrakt wbudowanego LLM dla notatek).
    static let contextLength = 8192

    let lease: LLMLease
    let runtime: any LLMRuntime
    let modelURL: URL
    let keepWarm: @Sendable () -> Duration

    init(
        lease: LLMLease, runtime: any LLMRuntime, modelURL: URL,
        keepWarm: @escaping @Sendable () -> Duration = { .seconds(60) }
    ) {
        self.lease = lease
        self.runtime = runtime
        self.modelURL = modelURL
        self.keepWarm = keepWarm
    }

    var key: LLMLease.Key { .init(modelID: modelURL.path, contextLength: runtime.contextLength) }
}

/// What the pipeline reports while it works (for the library's status line).
enum NotesEvent: Equatable, Sendable {
    /// Another model (dictation's, for example) holds the memory; the pipeline waits and asks again.
    case waitingForModel
    case map(done: Int, total: Int)
    case reduce
    case finishing
}

struct NotesResult: Equatable, Sendable {
    enum Status: String, Sendable { case ok, partial, failed }

    var status: Status
    /// Composed by code from verified points; `nil` when nothing could be made (`failed`) or nothing was said.
    var markdown: String?
    /// Points whose quote is not in the recording, left out (`notes_dropped_count`).
    var droppedCount: Int
    /// Chunks (or halves of chunks) the model could not process.
    var failedChunks: [String]
    var chunkCount: Int
    var verifiedPointCount: Int
    /// REDUCE failed somewhere and the sections were composed in code order.
    var reduceFailed: Bool
    var summaryReplaced: Bool
    var rejectedIDs: Int
    var language: NotesLanguage
    var promptVersion: String
    /// Points whose text said more than the quote and was replaced by the transcript's own words.
    var repairedCount = 0
    /// Decisions and tasks that were questions in the transcript and became open questions.
    var downgradedCount = 0
    /// Verified points the REDUCE answer left out that were added back.
    var backfilledCount = 0
    /// The decisions, tasks and open questions that stand in the notes, with their quotes (for the regression
    /// tests; nothing stores or shows them).
    var points: [NotesPoint] = []
    /// The summary points that stand in the notes as key points, in time order (for the regression tests;
    /// nothing stores or shows them).
    var keyPoints: [NotesPoint] = []
}

enum NotesFailure: Error, Equatable {
    /// The model could not be loaded.
    case modelUnavailable
    /// Another model kept the memory for the whole waiting time.
    case modelBusy
}

/// MAP → REDUCE over the transcript on the built-in model (spec: Architecture → Notatki).
///
/// Every request goes through the `LLMLease` at `background` priority. Dictation always goes first, and it wins
/// on the same model file even though its context length (4096) is not the notes' (8192): the lease then takes
/// the notes' lease away (`ModelLeaseError.yielded`), the running generation is cancelled between two tokens,
/// dictation's model is loaded, and `NotesLease` takes a new lease after dictation released it and repeats the
/// interrupted request (it is not a failure and not a retry; the notes' time limit does not run meanwhile). The notes wait out the lease's grace period after dictation (15 s), their waits add up to `busyLimit` for the whole job, and one request gives up (`NotesFailure.modelBusy`, which ends the job, never a chunk retry) after 20 takeovers. A
/// different model file in use makes the job wait ("Czeka na model"). A chunk gets one retry (a failed or
/// malformed answer, a timeout, or a doubled token limit when the answer was cut off; a cut-off answer is never
/// taken as a result) and, when the prompt does not fit the context, one split into halves. Whatever cannot be
/// done leaves the notes `partial`, never wrong.
struct NotesPipeline: Sendable {
    struct Configuration: Sendable {
        var chunkTokens = TranscriptChunker.defaultChunkTokens
        var reduceInputTokens = 4500
        var mapMaxTokens = 1000
        var reduceMaxTokens = 1500
        var mapTimeout: Duration = .seconds(300)
        var reduceTimeout: Duration = .seconds(600)
        var busyPoll: Duration = .seconds(5)
        /// How long the whole job may wait for the model, summed over every wait (the start and each time
        /// dictation took the model over); it is not restarted by a yield.
        var busyLimit: Duration = .seconds(1800)
        /// The language of the headings when the transcript does not tell.
        var fallbackLanguage: NotesLanguage = .english
        /// The generation time the semantic verifier may take in one run, all its points together (counted like
        /// `mapTimeout`: only while a request runs on the model). One check is a prompt of about 500 to 900
        /// tokens and an answer of about six, so roughly a second on the 4B model; 120 s covers the 60 to 90
        /// points of an hour-long meeting and caps the extra time at about one and a half MAP passes of such a
        /// meeting (about 80 s). Points left when it runs out get no verdict and keep the guard's result.
        var verifierBudget: Duration = .seconds(120)

        init() {}
    }

    let model: NotesModel
    let configuration: Configuration
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Where the stage trace goes (`NotesTrace`); `nil`, the default, records nothing.
    private let trace: NotesTraceSink?
    /// Builds the semantic verifier over the notes' own model; `nil` leaves the guard's rules alone.
    private let makeVerifier: NotesVerifierFactory?

    init(
        model: NotesModel, configuration: Configuration = Configuration(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        trace: NotesTraceSink? = nil, verifier: NotesVerifierFactory? = NotesPipeline.defaultVerifier
    ) {
        self.model = model
        self.configuration = configuration
        self.sleep = sleep
        self.trace = trace
        makeVerifier = verifier
    }

    /// Writes the notes. Throws `CancellationError` when cancelled and `NotesFailure` when the model cannot be
    /// had; every other trouble is in the result.
    func run(
        utterances: [NotesUtterance], onEvent: @escaping @Sendable (NotesEvent) -> Void = { _ in }
    ) async throws -> NotesResult {
        let chunks = TranscriptChunker(chunkTokens: configuration.chunkTokens).chunks(from: utterances)
        let verifier = NotesGuard(utterances: utterances)
        let recorder = trace.map { NotesTraceRecorder(sink: $0) }
        recorder?.emit(
            .started(
                schemaVersion: NotesTrace.schemaVersion, promptVersion: NotesPrompt.version,
                utterances: utterances.count, chunks: chunks.count))
        guard !chunks.isEmpty else {
            let result = NotesResult(
                status: .ok, markdown: nil, droppedCount: 0, failedChunks: [], chunkCount: 0, verifiedPointCount: 0,
                reduceFailed: false, summaryReplaced: false, rejectedIDs: 0, language: verifier.language,
                promptVersion: String(NotesPrompt.version))
            recorder?.finish(result)
            return result
        }
        let lease = NotesLease(model: model, configuration: configuration, sleep: sleep, onEvent: onEvent)
        try await lease.open()
        do {
            let result = try await work(
                chunks: chunks, utterances: utterances, verifier: verifier, lease: lease, recorder: recorder,
                onEvent: onEvent)
            recorder?.finish(result)
            await lease.release()
            return result
        } catch {
            await lease.release()
            throw error
        }
    }

    // MARK: Flow

    private func work(
        chunks: [TranscriptChunk], utterances: [NotesUtterance], verifier: NotesGuard, lease: NotesLease,
        recorder: NotesTraceRecorder?, onEvent: @Sendable (NotesEvent) -> Void
    ) async throws -> NotesResult {
        var proposed: [NotesPoint] = []
        var failed: [String] = []
        var failedWhole = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onEvent(.map(done: index, total: chunks.count))
            let outcome = try await mapChunk(
                chunk, language: verifier.language, lease: lease, canSplit: true, firstPoint: proposed.count + 1,
                recorder: recorder)
            proposed.append(contentsOf: outcome.points)
            failed.append(contentsOf: outcome.failed)
            if outcome.failed.contains(chunk.id) { failedWhole += 1 }
        }
        onEvent(.map(done: chunks.count, total: chunks.count))

        func result(
            status: NotesResult.Status, markdown: String?, dropped: Int = 0, points: Int = 0,
            reduceFailed: Bool = false, replaced: Bool = false, rejected: Int = 0, repaired: Int = 0,
            downgraded: Int = 0, backfilled: Int = 0, kept: [NotesPoint] = [], keyPoints: [NotesPoint] = []
        ) -> NotesResult {
            NotesResult(
                status: status, markdown: markdown, droppedCount: dropped, failedChunks: failed,
                chunkCount: chunks.count, verifiedPointCount: points, reduceFailed: reduceFailed,
                summaryReplaced: replaced, rejectedIDs: rejected, language: verifier.language,
                promptVersion: String(NotesPrompt.version), repairedCount: repaired, downgradedCount: downgraded,
                backfilledCount: backfilled, points: kept, keyPoints: keyPoints)
        }
        if failedWhole == chunks.count { return result(status: .failed, markdown: nil) }

        // The code, not the model, names the points.
        for index in proposed.indices { proposed[index].id = "p\(index + 1)" }
        let checked = verifier.verifyPoints(proposed)
        var verdict = checked
        var verifierTrace: NotesTraceVerifier?
        if let makeVerifier {
            let reviewed = try await review(checked, notesGuard: verifier, lease: lease, make: makeVerifier)
            verdict = reviewed.verdict
            verifierTrace = reviewed.trace
        }
        recorder?.emit(
            .verified(NotesTraceVerification(proposed: proposed.count, verdict: verdict, verifier: verifierTrace)))
        let unique = Self.deduplicated(verdict.verified)
        let points = Self.ordered(unique)
        recorder?.emit(
            .deduplicated(
                removedIDs: NotesTrace.removedIDs(from: verdict.verified, kept: unique), keptIDs: points.map(\.id)))

        onEvent(.reduce)
        let participants = Self.participants(of: utterances)
        let labels = NotesComposer.Labels.forLanguage(verifier.language, fallback: configuration.fallbackLanguage)
        let flowStatus: NotesResult.Status = failed.isEmpty ? .ok : .partial

        if points.isEmpty {
            // Nothing to organise. If part of the recording could not be read the empty result says nothing.
            if !failed.isEmpty { return result(status: .failed, markdown: nil, dropped: verdict.dropped) }
            let empty = NotesGuard.ReduceVerdict(
                decisions: [], tasks: [], questions: [], summary: nil, summaryReplaced: false, rejectedIDs: 0)
            let markdown = NotesComposer.markdown(verdict: empty, participants: participants, labels: labels)
            return result(
                status: .ok, markdown: markdown, dropped: verdict.dropped, repaired: verdict.repaired,
                downgraded: verdict.downgraded)
        }

        let reduced = try await reduce(points: points, lease: lease, recorder: recorder)
        onEvent(.finishing)
        let final: NotesGuard.ReduceVerdict
        if let recorder {
            // The same check as `verifyReduce`, with the guard's record of every id for the trace.
            let audited = verifier.auditedVerifyReduce(reduced.output, points: points)
            final = audited.verdict
            recorder.reduced(
                points: points, proposed: proposed, verdict: final, audit: audited.audit,
                reduceFailed: reduced.failed, summaryShown: NotesComposer.shownSummary(of: final) != nil)
        } else {
            final = verifier.verifyReduce(reduced.output, points: points)
        }
        let markdown = NotesComposer.markdown(verdict: final, participants: participants, labels: labels)
        return result(
            status: reduced.failed ? .partial : flowStatus, markdown: markdown, dropped: verdict.dropped,
            points: points.count, reduceFailed: reduced.failed, replaced: final.summaryReplaced,
            rejected: final.rejectedIDs, repaired: verdict.repaired, downgraded: verdict.downgraded,
            backfilled: final.backfilled, kept: final.decisions + final.tasks + final.questions,
            keyPoints: final.keyPoints)
    }

    /// Chunk overlap and a model that says a thing twice give the same point twice; the first one stays. Two
    /// points are the same when they have the same kind and the same quoted sentence (the utterance and the
    /// sentence in it, not the span the model happened to quote); two tasks in one sentence stay apart when
    /// they have different people.
    static func deduplicated(_ points: [NotesPoint]) -> [NotesPoint] {
        var seen = Set<String>()
        return points.filter { point in
            let place =
                point.utterance.map { "\($0).\(point.sentence ?? -1)" }
                ?? NotesText.words(point.quote).joined(separator: " ")
            let who = point.kind == .task ? NotesText.words(point.person ?? "").joined(separator: " ") : ""
            return seen.insert(point.kind.rawValue + "|" + place + "|" + who).inserted
        }
    }

    /// Time order; points of the same time keep the order they were found in (an explicit, stable sort).
    static func ordered(_ points: [NotesPoint]) -> [NotesPoint] {
        points.enumerated().sorted { ($0.element.timeMs, $0.offset) < ($1.element.timeMs, $1.offset) }.map(\.element)
    }

    static func participants(of utterances: [NotesUtterance]) -> [String] {
        var seen = Set<String>()
        return utterances.map(\.speaker).filter { seen.insert($0).inserted }
    }

    // MARK: Semantic verifier

    /// Asks the verifier about every point the guard kept or repaired in a way it may undo
    /// (`NotesGuard.PointReview.claim`), one at a time on the notes' lease, within `verifierBudget` of generation
    /// time, and applies the answers (`NotesGuard.applyingVerifications`). Only the points the deduplication keeps
    /// are asked (it does not depend on the text). Cancelling the run throws; running out of time, a failed or
    /// malformed answer leave a point as the guard left it.
    private func review(
        _ verdict: NotesGuard.PointVerdict, notesGuard: NotesGuard, lease: NotesLease,
        make: @escaping NotesVerifierFactory
    ) async throws -> (verdict: NotesGuard.PointVerdict, trace: NotesTraceVerifier) {
        let kept = Set(Self.deduplicated(verdict.verified).map(\.id))
        var requests: [NotesVerifierRequestItem] = []
        for (point, review) in zip(verdict.verified, verdict.reviews) where kept.contains(point.id) {
            guard let claim = review.claim(of: point) else { continue }
            requests.append(.init(id: point.id, request: notesGuard.verificationRequest(for: point, claim: claim)))
        }
        var trace = NotesTraceVerifier(promptVersion: NotesVerifierPrompt.version, eligible: requests.count)
        guard !requests.isEmpty else { return (verdict, trace) }
        let items = requests

        let store = NotesVerificationStore()
        let contextLength = model.key.contextLength
        let started = ContinuousClock.now
        let finished = try await NotesDeadline.run(limit: configuration.verifierBudget, sleep: sleep) { phase in
            phase(.running)
            let verifier = make(NotesLeaseRuntime(lease: lease, contextLength: contextLength, onPhase: phase))
            for item in items {
                if Task.isCancelled { return false }
                store.record(item.id, await verifier.verification(item.request))
            }
            return true
        }
        let results = store.close()
        try Task.checkCancellation()
        let elapsed = ContinuousClock.now - started
        trace.elapsedMs = Int(
            elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        trace.budgetExceeded = finished == nil
        for verification in results.values {
            trace.asked += 1
            guard verification.source == .answered else {
                trace.failed += 1
                continue
            }
            switch verification.verdict {
            case .supported: trace.supported += 1
            case .weaker: trace.weaker += 1
            case .unsupported: trace.unsupported += 1
            }
        }
        trace.notAsked = requests.count - trace.asked
        let applied = NotesGuard.applyingVerifications(results, to: verdict)
        trace.restoredModelText = applied.effect.restoredModelText
        trace.rejectedKept = applied.effect.rejectedKept
        return (applied.verdict, trace)
    }

    // MARK: MAP

    private struct MapOutcome {
        var points: [NotesPoint] = []
        var failed: [String] = []
    }

    /// `firstPoint` is the number the code gives the chunk's first proposed point (`p<firstPoint>`).
    private func mapChunk(
        _ chunk: TranscriptChunk, language: NotesLanguage, lease: NotesLease, canSplit: Bool, firstPoint: Int,
        recorder: NotesTraceRecorder?
    ) async throws -> MapOutcome {
        var attempts = NotesTraceAttempts()
        let completion = try await complete(
            lease, maxTokens: configuration.mapMaxTokens, timeout: configuration.mapTimeout,
            messages: { NotesPrompt.mapMessages(chunk: chunk, language: language, reminder: $0) },
            parse: { raw -> [NotesPoint]? in
                if case .points(let points) = NotesParser.parseMap(raw) { points } else { nil }
            }, attempts: &attempts)
        let tried = attempts
        func report(_ outcome: NotesTraceChunk.Outcome, _ points: [NotesPoint] = []) {
            recorder?.emit(
                .mapChunk(
                    NotesTraceChunk(
                        chunk: chunk, attempts: tried, outcome: outcome, proposed: points, firstPointNumber: firstPoint
                    )))
        }
        switch completion {
        case .value(let points):
            report(.points, points)
            return MapOutcome(points: points)
        case .failed:
            report(.failed)
            return MapOutcome(failed: [chunk.id])
        case .promptTooLong:
            guard canSplit, let halves = chunk.split() else {
                report(.failed)
                return MapOutcome(failed: [chunk.id])
            }
            report(.split)
            var merged = MapOutcome()
            for half in halves {
                let outcome = try await mapChunk(
                    half, language: language, lease: lease, canSplit: false,
                    firstPoint: firstPoint + merged.points.count,
                    recorder: recorder)
                merged.points.append(contentsOf: outcome.points)
                merged.failed.append(contentsOf: outcome.failed)
            }
            return merged
        }
    }

    // MARK: REDUCE

    private struct Reduced {
        var output = NotesReduceOutput()
        var failed = false
    }

    private func cost(of point: NotesPoint) -> Int {
        NotesText.estimateTokens(NotesPrompt.reduceLine(point), fallback: .unknown) + 4
    }

    private func reduce(
        points: [NotesPoint], lease: NotesLease, recorder: NotesTraceRecorder?
    ) async throws -> Reduced {
        if points.count <= 1 || points.reduce(0, { $0 + cost(of: $1) }) <= configuration.reduceInputTokens {
            recorder?.reduceBatches(1)
            return try await reduceSingle(points, lease: lease, recorder: recorder)
        }
        let batches = Self.batches(points, budget: configuration.reduceInputTokens, cost: { cost(of: $0) })
        recorder?.reduceBatches(batches.count)
        return try await reduceBatches(batches, lease: lease, recorder: recorder)
    }

    /// One request per batch, then the sections joined in order and the partial summaries merged into one.
    private func reduceBatches(
        _ batches: [[NotesPoint]], lease: NotesLease, recorder: NotesTraceRecorder?
    ) async throws -> Reduced {
        var merged = Reduced()
        var summaries: [String] = []
        for batch in batches {
            let part = try await reduceSingle(batch, lease: lease, recorder: recorder)
            merged.output.decisions.append(contentsOf: part.output.decisions)
            merged.output.tasks.append(contentsOf: part.output.tasks)
            merged.output.questions.append(contentsOf: part.output.questions)
            if let summary = part.output.summary { summaries.append(summary) }
            merged.failed = merged.failed || part.failed
        }
        let summary = try await mergeSummaries(summaries, lease: lease, recorder: recorder)
        merged.output.summary = summary.text
        merged.failed = merged.failed || summary.failed
        return merged
    }

    private func reduceSingle(
        _ points: [NotesPoint], lease: NotesLease, recorder: NotesTraceRecorder?
    ) async throws -> Reduced {
        var attempts = NotesTraceAttempts()
        let completion = try await complete(
            lease, maxTokens: configuration.reduceMaxTokens, timeout: configuration.reduceTimeout,
            messages: { NotesPrompt.reduceMessages(points: points, reminder: $0) },
            parse: { NotesParser.parseReduce($0) }, attempts: &attempts)
        let tried = attempts
        func report(_ outcome: NotesTraceReduceRequest.Outcome) {
            recorder?.reduceRequest(
                stage: .sections, inputs: points.count, pointIDs: points.map(\.id), attempts: tried, outcome: outcome)
        }
        switch completion {
        case .value(let output):
            report(.value)
            return Reduced(output: output)
        case .promptTooLong where points.count > 1:
            report(.split)
            let middle = points.count / 2
            return try await reduceBatches(
                [Array(points[..<middle]), Array(points[middle...])], lease: lease, recorder: recorder)
        case .promptTooLong, .failed:
            report(.codeOrder)
            return Reduced(output: Self.codeOrder(points), failed: true)
        }
    }

    /// REDUCE could not be had: every point of a kind, in time order, and no paragraph (the guard composes it).
    static func codeOrder(_ points: [NotesPoint]) -> NotesReduceOutput {
        NotesReduceOutput(
            decisions: points.filter { $0.kind == .decision }.map(\.id),
            tasks: points.filter { $0.kind == .task }.map(\.id),
            questions: points.filter { $0.kind == .question }.map(\.id), summary: nil)
    }

    static func batches(_ points: [NotesPoint], budget: Int, cost: (NotesPoint) -> Int) -> [[NotesPoint]] {
        var result: [[NotesPoint]] = []
        var current: [NotesPoint] = []
        var used = 0
        for point in points {
            let next = cost(point)
            if !current.isEmpty, used + next > budget {
                result.append(current)
                current = []
                used = 0
            }
            current.append(point)
            used += next
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The deepest merge of partial summaries; each level at least halves their number, so this is never reached
    /// with a sane budget, and a budget too small for two summaries gives up at once.
    private static let maxMergeDepth = 8

    /// Merges partial summaries into one paragraph, a level at a time while they do not fit one request. When
    /// two of them do not fit together (or the levels run out) it gives up with `failed`, and the guard composes
    /// the paragraph from the points.
    private func mergeSummaries(
        _ summaries: [String], lease: NotesLease, recorder: NotesTraceRecorder?, depth: Int = 0
    ) async throws -> (text: String?, failed: Bool) {
        let texts = summaries.map(NotesGuard.plain).filter { !$0.isEmpty }.map {
            NotesText.truncated($0, limit: NotesGuard.maxSummaryLength)
        }
        if texts.isEmpty { return (nil, false) }
        if texts.count == 1 { return (texts[0], false) }
        let total = texts.reduce(0) { $0 + NotesText.estimateTokens($1, fallback: .unknown) + 4 }
        if total <= configuration.reduceInputTokens {
            var attempts = NotesTraceAttempts()
            let completion = try await complete(
                lease, maxTokens: configuration.reduceMaxTokens, timeout: configuration.reduceTimeout,
                messages: { NotesPrompt.summaryMessages(summaries: texts, reminder: $0) },
                parse: { NotesParser.parseSummary($0) }, attempts: &attempts)
            let tried = attempts
            if case .value(let text) = completion {
                recorder?.reduceRequest(
                    stage: .summaryMerge, inputs: texts.count, pointIDs: [], attempts: tried, outcome: .value)
                return (text, false)
            }
            recorder?.reduceRequest(
                stage: .summaryMerge, inputs: texts.count, pointIDs: [], attempts: tried, outcome: .failed)
            return (nil, true)
        }
        if texts.count <= 2 || depth >= Self.maxMergeDepth {
            recorder?.summaryMergeGivenUp()
            return (nil, true)
        }
        var size = texts.count - 1
        var used = 0
        for (index, text) in texts.enumerated() {
            used += NotesText.estimateTokens(text, fallback: .unknown) + 4
            if used > configuration.reduceInputTokens {
                size = min(max(index, 2), texts.count - 1)
                break
            }
        }
        return try await mergeInBatches(texts, size: size, lease: lease, recorder: recorder, depth: depth + 1)
    }

    private func mergeInBatches(
        _ texts: [String], size: Int, lease: NotesLease, recorder: NotesTraceRecorder?, depth: Int
    ) async throws -> (text: String?, failed: Bool) {
        var next: [String] = []
        var failed = false
        var start = 0
        while start < texts.count {
            let batch = Array(texts[start..<min(start + size, texts.count)])
            start += size
            let merged = try await mergeSummaries(batch, lease: lease, recorder: recorder, depth: depth)
            failed = failed || merged.failed
            if let text = merged.text { next.append(text) }
        }
        if next.count <= 1 { return (next.first, failed) }
        let final = try await mergeSummaries(next, lease: lease, recorder: recorder, depth: depth)
        return (final.text, failed || final.failed)
    }

    // MARK: Completion

    private enum Completion<Value: Sendable>: Sendable {
        case value(Value)
        case promptTooLong
        case failed
    }

    private enum AttemptError: Error { case truncated, malformed, timedOut }

    /// Tokens kept free in the context for the chat template around the messages.
    private static let templateMargin = 64

    /// The tokens a prompt takes (the ADR 0004 heuristic, which errs high for Polish).
    static func promptTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + NotesText.estimateTokens($1.content, fallback: .unknown) + 8 }
    }

    /// One request with the retry rules: a failure, a timeout or an answer that does not parse is tried once more
    /// (with a format reminder); an answer cut off by the token limit once more with a larger limit (twice, but
    /// never so large that prompt and answer exceed the context; when there is no room to grow, the cut-off
    /// answer is a failure) and is never used as it is. A prompt that does not fit the context is reported to
    /// the caller, which splits its input. The time limit counts generation only (`NotesDeadline`). `attempts`
    /// counts what happened, for the trace; it changes nothing.
    private func complete<Value: Sendable>(
        _ lease: NotesLease, maxTokens: Int, timeout: Duration, messages: (Bool) -> [ChatMessage],
        parse: (String) -> Value?, attempts: inout NotesTraceAttempts
    ) async throws -> Completion<Value> {
        var limit = maxTokens
        var reminder = false
        var retried = false
        let context = model.key.contextLength
        let sleep = self.sleep
        attempts.firstMaxTokens = maxTokens
        while true {
            try Task.checkCancellation()
            let prompt = messages(reminder)
            let estimate = Self.promptTokens(prompt)
            if attempts.requests == 0 { attempts.promptTokens = estimate }
            let room = context - estimate - Self.templateMargin
            guard room > 0 else {
                attempts.promptTooLong = true
                return .promptTooLong
            }
            limit = min(limit, room)
            let tokens = limit
            attempts.requests += 1
            attempts.lastMaxTokens = tokens
            do {
                let generated = try await NotesDeadline.run(limit: timeout, sleep: sleep) { phase in
                    try await lease.generateResult(messages: prompt, maxTokens: tokens, onPhase: phase)
                }
                guard let result = generated else { throw AttemptError.timedOut }
                if result.stoppedByTokenLimit { throw AttemptError.truncated }
                guard let value = parse(result.text) else { throw AttemptError.malformed }
                return .value(value)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NotesFailure {
                // The model cannot be had (busy for too long, or gone): the job ends, nothing is retried.
                throw error
            } catch let error as LlamaError {
                if case .promptTooLong = error {
                    attempts.promptTooLong = true
                    return .promptTooLong
                }
                attempts.errors += 1
                if retried { return .failed }
                retried = true
            } catch {
                try Task.checkCancellation()
                switch error as? AttemptError {
                case .truncated?: attempts.truncated += 1
                case .malformed?: attempts.malformed += 1
                case .timedOut?: attempts.timedOut += 1
                case nil: attempts.errors += 1
                }
                if retried { return .failed }
                retried = true
                switch error as? AttemptError {
                case .truncated?:
                    let larger = min(limit * 2, room)
                    if larger <= limit { return .failed }
                    limit = larger
                case .malformed?: reminder = true
                default: break
                }
            }
        }
    }
}

/// The notes' lease on the model: takes it (waiting while another model is in use) and, when dictation took
/// the model over (`ModelLeaseError.yielded`), takes it again once dictation is done and repeats the request.
final class NotesLease: Sendable {
    private let model: NotesModel
    private let configuration: NotesPipeline.Configuration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onEvent: @Sendable (NotesEvent) -> Void
    private let current = Mutex<LLMHandle?>(nil)
    /// The time the job spent waiting for the model so far.
    private let waited = Mutex(Duration.zero)

    /// How many times dictation may take the model from one request before the job gives up (`modelBusy`): a
    /// yield is not a failure and not a retry, but it must not go on for ever.
    static let maxYieldsPerRequest = 20

    init(
        model: NotesModel, configuration: NotesPipeline.Configuration,
        sleep: @escaping @Sendable (Duration) async throws -> Void, onEvent: @escaping @Sendable (NotesEvent) -> Void
    ) {
        self.model = model
        self.configuration = configuration
        self.sleep = sleep
        self.onEvent = onEvent
    }

    func open() async throws {
        _ = try await handle()
    }

    func release() async {
        let handle = current.withLock { handle -> LLMHandle? in
            defer { handle = nil }
            return handle
        }
        await handle?.release()
    }

    func generateResult(
        messages: [ChatMessage], maxTokens: Int, onPhase: (@Sendable (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult {
        var yields = 0
        while true {
            let held = try await handle()
            do {
                return try await held.generateResult(messages: messages, maxTokens: maxTokens, onPhase: onPhase)
            } catch ModelLeaseError.yielded {
                // Dictation has the model: the time limit stops (queued) until a new lease is taken.
                onPhase?(.queued)
                current.withLock { if $0 === held { $0 = nil } }
                await held.release()
                yields += 1
                if yields > Self.maxYieldsPerRequest { throw NotesFailure.modelBusy }
            } catch ModelLeaseError.busy {
                throw NotesFailure.modelBusy
            }
        }
    }

    private func handle() async throws -> LLMHandle {
        if let existing = current.withLock({ $0 }) { return existing }
        while true {
            try Task.checkCancellation()
            do {
                let handle = try await model.lease.acquire(
                    key: model.key, runtime: model.runtime, modelURL: model.modelURL, priority: .background,
                    keepWarm: model.keepWarm)
                current.withLock { $0 = handle }
                return handle
            } catch let error as ModelLeaseError where error == .busy {
                if waited.withLock({ $0 }) >= configuration.busyLimit { throw NotesFailure.modelBusy }
                onEvent(.waitingForModel)
                try await sleep(configuration.busyPoll)
                waited.withLock { $0 += configuration.busyPoll }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NotesFailure.modelUnavailable
            }
        }
    }
}

/// Builds the semantic verifier over the runtime the notes hold (`NotesLeaseRuntime`: the same model as MAP,
/// no second load).
typealias NotesVerifierFactory = @Sendable (any LLMRuntime) -> any NotesVerifying

extension NotesPipeline {
    /// The one switch of the semantic verifier (spec `2026-11-06-meeting-notes-semantic-verifier`, Faza B). Off,
    /// the notes are what the guard's rules alone make of them, as before.
    ///
    /// Off by default: in the evaluation on 2026-11-06 the verifier raised the share of points shown in the
    /// model's own words from about 9-19% to about 45-53% (Qwen3-4B), but the blind judges' faithfulness fell on
    /// the Polish recording (3 -> 1, unsupported claims 3 -> 9 and 10) and the overall scores did not improve
    /// beyond noise (spec 2026-11-06-meeting-notes-semantic-verifier, results in the eval archive). Switch on
    /// only after a verifier that passes a stricter gate.
    static let notesVerifierEnabled = false

    /// `LLMNotesVerifier` when `notesVerifierEnabled`, else nil.
    static var defaultVerifier: NotesVerifierFactory? {
        guard notesVerifierEnabled else { return nil }
        return { @Sendable runtime in LLMNotesVerifier(runtime: runtime) }
    }
}

/// One point to verify: its id and the request.
struct NotesVerifierRequestItem: Sendable {
    var id: String
    var request: NotesVerificationRequest
}

/// The verdicts gathered while the verifier runs. Closed once the run is over (finished, out of time or
/// cancelled): a verdict that comes later is dropped, so a point cut off by the time limit has none.
final class NotesVerificationStore: Sendable {
    private struct State {
        var results: [String: NotesVerification] = [:]
        var closed = false
    }

    private let state = Mutex(State())

    func record(_ id: String, _ verification: NotesVerification) {
        state.withLock { state in
            if !state.closed { state.results[id] = verification }
        }
    }

    func close() -> [String: NotesVerification] {
        state.withLock { state in
            state.closed = true
            return state.results
        }
    }
}

/// The notes' lease seen as an `LLMRuntime`, so `LLMNotesVerifier` generates on the model the notes already hold
/// (with the lease's takeover rules) and reports the request's phase to the verifier's time limit. It never loads
/// or unloads anything itself.
struct NotesLeaseRuntime: LLMRuntime {
    let lease: NotesLease
    let contextLength: Int
    let onPhase: @Sendable (GenerationPhase) -> Void

    var isLoaded: Bool { get async { true } }
    func load(modelAt url: URL) async throws {}
    func unload() async {}

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await generateResult(messages: messages, maxTokens: maxTokens).text
    }

    func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        try await lease.generateResult(messages: messages, maxTokens: maxTokens, onPhase: onPhase)
    }
}
