import Foundation
import PounceSpeech

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
}

enum NotesFailure: Error, Equatable {
    /// The model could not be loaded.
    case modelUnavailable
    /// Another model kept the memory for the whole waiting time.
    case modelBusy
}

/// MAP → REDUCE over the transcript on the built-in model (spec: Architecture → Notatki).
///
/// Every request goes through the `LLMLease` at `background` priority: when dictation asks for the model the
/// running generation is cancelled between two tokens by the lease and starts again afterwards, so this code
/// just waits. A chunk gets one retry (a failed or malformed answer, a timeout, or a doubled token limit when the
/// answer was cut off; a cut-off answer is never taken as a result) and, when the prompt does not fit the
/// context, one split into halves. Whatever cannot be done leaves the notes `partial`, never wrong.
struct NotesPipeline: Sendable {
    struct Configuration: Sendable {
        var chunkTokens = TranscriptChunker.defaultChunkTokens
        var reduceInputTokens = 4500
        var mapMaxTokens = 700
        var reduceMaxTokens = 1500
        var mapTimeout: Duration = .seconds(300)
        var reduceTimeout: Duration = .seconds(600)
        var busyPoll: Duration = .seconds(5)
        var busyLimit: Duration = .seconds(1800)
        /// The language of the headings when the transcript does not tell.
        var fallbackLanguage: NotesLanguage = .english

        init() {}
    }

    let model: NotesModel
    let configuration: Configuration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        model: NotesModel, configuration: Configuration = Configuration(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.model = model
        self.configuration = configuration
        self.sleep = sleep
    }

    /// Writes the notes. Throws `CancellationError` when cancelled and `NotesFailure` when the model cannot be
    /// had; every other trouble is in the result.
    func run(
        utterances: [NotesUtterance], onEvent: @escaping @Sendable (NotesEvent) -> Void = { _ in }
    ) async throws -> NotesResult {
        let chunks = TranscriptChunker(chunkTokens: configuration.chunkTokens).chunks(from: utterances)
        let verifier = NotesGuard(utterances: utterances)
        guard !chunks.isEmpty else {
            return NotesResult(
                status: .ok, markdown: nil, droppedCount: 0, failedChunks: [], chunkCount: 0, verifiedPointCount: 0,
                reduceFailed: false, summaryReplaced: false, rejectedIDs: 0, language: verifier.language,
                promptVersion: String(NotesPrompt.version))
        }
        let handle = try await acquire(onEvent: onEvent)
        do {
            let result = try await work(
                chunks: chunks, utterances: utterances, verifier: verifier, handle: handle, onEvent: onEvent)
            await handle.release()
            return result
        } catch {
            await handle.release()
            throw error
        }
    }

    // MARK: Lease

    private func acquire(onEvent: @Sendable (NotesEvent) -> Void) async throws -> LLMHandle {
        var waited = Duration.zero
        while true {
            try Task.checkCancellation()
            do {
                return try await model.lease.acquire(
                    key: model.key, runtime: model.runtime, modelURL: model.modelURL, priority: .background,
                    keepWarm: model.keepWarm)
            } catch let error as ModelLeaseError where error == .busy {
                if waited >= configuration.busyLimit { throw NotesFailure.modelBusy }
                onEvent(.waitingForModel)
                try await sleep(configuration.busyPoll)
                waited += configuration.busyPoll
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NotesFailure.modelUnavailable
            }
        }
    }

    // MARK: Flow

    private func work(
        chunks: [TranscriptChunk], utterances: [NotesUtterance], verifier: NotesGuard, handle: LLMHandle,
        onEvent: @Sendable (NotesEvent) -> Void
    ) async throws -> NotesResult {
        var proposed: [NotesPoint] = []
        var failed: [String] = []
        var failedWhole = 0
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onEvent(.map(done: index, total: chunks.count))
            let outcome = try await mapChunk(chunk, handle: handle, canSplit: true)
            proposed.append(contentsOf: outcome.points)
            failed.append(contentsOf: outcome.failed)
            if outcome.failed.contains(chunk.id) { failedWhole += 1 }
        }
        onEvent(.map(done: chunks.count, total: chunks.count))

        func result(
            status: NotesResult.Status, markdown: String?, dropped: Int = 0, points: Int = 0,
            reduceFailed: Bool = false, replaced: Bool = false, rejected: Int = 0
        ) -> NotesResult {
            NotesResult(
                status: status, markdown: markdown, droppedCount: dropped, failedChunks: failed,
                chunkCount: chunks.count, verifiedPointCount: points, reduceFailed: reduceFailed,
                summaryReplaced: replaced, rejectedIDs: rejected, language: verifier.language,
                promptVersion: String(NotesPrompt.version))
        }
        if failedWhole == chunks.count { return result(status: .failed, markdown: nil) }

        // The code, not the model, names the points.
        for index in proposed.indices { proposed[index].id = "p\(index + 1)" }
        let verdict = verifier.verifyPoints(proposed)
        let points = Self.deduplicated(verdict.verified).sorted { $0.timeMs < $1.timeMs }

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
            return result(status: .ok, markdown: markdown, dropped: verdict.dropped)
        }

        let reduced = try await reduce(points: points, handle: handle)
        onEvent(.finishing)
        let final = verifier.verifyReduce(reduced.output, points: points)
        let markdown = NotesComposer.markdown(verdict: final, participants: participants, labels: labels)
        return result(
            status: reduced.failed ? .partial : flowStatus, markdown: markdown, dropped: verdict.dropped,
            points: points.count, reduceFailed: reduced.failed, replaced: final.summaryReplaced,
            rejected: final.rejectedIDs)
    }

    /// Chunk overlap and a model that says a thing twice give the same point twice; the first one stays.
    static func deduplicated(_ points: [NotesPoint]) -> [NotesPoint] {
        var seen = Set<String>()
        return points.filter { point in
            let key = point.kind.rawValue + "|" + NotesText.words(point.quote).joined(separator: " ")
            return seen.insert(key).inserted
        }
    }

    static func participants(of utterances: [NotesUtterance]) -> [String] {
        var seen = Set<String>()
        return utterances.map(\.speaker).filter { seen.insert($0).inserted }
    }

    // MARK: MAP

    private struct MapOutcome {
        var points: [NotesPoint] = []
        var failed: [String] = []
    }

    private func mapChunk(_ chunk: TranscriptChunk, handle: LLMHandle, canSplit: Bool) async throws -> MapOutcome {
        let completion = try await complete(
            handle, maxTokens: configuration.mapMaxTokens, timeout: configuration.mapTimeout,
            messages: { NotesPrompt.mapMessages(chunk: chunk, reminder: $0) },
            parse: { raw -> [NotesPoint]? in
                if case .points(let points) = NotesParser.parseMap(raw) { points } else { nil }
            })
        switch completion {
        case .value(let points):
            return MapOutcome(points: points)
        case .failed:
            return MapOutcome(failed: [chunk.id])
        case .promptTooLong:
            guard canSplit, let halves = chunk.split() else { return MapOutcome(failed: [chunk.id]) }
            var merged = MapOutcome()
            for half in halves {
                let outcome = try await mapChunk(half, handle: handle, canSplit: false)
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

    private func reduce(points: [NotesPoint], handle: LLMHandle) async throws -> Reduced {
        if points.count <= 1 || points.reduce(0, { $0 + cost(of: $1) }) <= configuration.reduceInputTokens {
            return try await reduceSingle(points, handle: handle)
        }
        let batches = Self.batches(points, budget: configuration.reduceInputTokens, cost: { cost(of: $0) })
        return try await reduceBatches(batches, handle: handle)
    }

    /// One request per batch, then the sections joined in order and the partial summaries merged into one.
    private func reduceBatches(_ batches: [[NotesPoint]], handle: LLMHandle) async throws -> Reduced {
        var merged = Reduced()
        var summaries: [String] = []
        for batch in batches {
            let part = try await reduceSingle(batch, handle: handle)
            merged.output.decisions.append(contentsOf: part.output.decisions)
            merged.output.tasks.append(contentsOf: part.output.tasks)
            merged.output.questions.append(contentsOf: part.output.questions)
            if let summary = part.output.summary { summaries.append(summary) }
            merged.failed = merged.failed || part.failed
        }
        let summary = try await mergeSummaries(summaries, handle: handle)
        merged.output.summary = summary.text
        merged.failed = merged.failed || summary.failed
        return merged
    }

    private func reduceSingle(_ points: [NotesPoint], handle: LLMHandle) async throws -> Reduced {
        let completion = try await complete(
            handle, maxTokens: configuration.reduceMaxTokens, timeout: configuration.reduceTimeout,
            messages: { NotesPrompt.reduceMessages(points: points, reminder: $0) },
            parse: { NotesParser.parseReduce($0) })
        switch completion {
        case .value(let output):
            return Reduced(output: output)
        case .promptTooLong where points.count > 1:
            let middle = points.count / 2
            return try await reduceBatches([Array(points[..<middle]), Array(points[middle...])], handle: handle)
        case .promptTooLong, .failed:
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

    /// Merges partial summaries into one paragraph, a level at a time while they do not fit one request.
    private func mergeSummaries(_ summaries: [String], handle: LLMHandle) async throws -> (text: String?, failed: Bool)
    {
        let texts = summaries.map(NotesGuard.plain).filter { !$0.isEmpty }
        if texts.isEmpty { return (nil, false) }
        if texts.count == 1 { return (texts[0], false) }
        let total = texts.reduce(0) { $0 + NotesText.estimateTokens($1, fallback: .unknown) + 4 }
        if total <= configuration.reduceInputTokens {
            let completion = try await complete(
                handle, maxTokens: configuration.reduceMaxTokens, timeout: configuration.reduceTimeout,
                messages: { NotesPrompt.summaryMessages(summaries: texts, reminder: $0) },
                parse: { NotesParser.parseSummary($0) })
            if case .value(let text) = completion { return (text, false) }
            return (nil, true)
        }
        var size = texts.count
        var used = 0
        for (index, text) in texts.enumerated() {
            used += NotesText.estimateTokens(text, fallback: .unknown) + 4
            if used > configuration.reduceInputTokens {
                size = max(index, 2)
                break
            }
        }
        return try await mergeInBatches(texts, size: size, handle: handle)
    }

    private func mergeInBatches(_ texts: [String], size: Int, handle: LLMHandle) async throws -> (
        text: String?, failed: Bool
    ) {
        var next: [String] = []
        var failed = false
        var start = 0
        while start < texts.count {
            let batch = Array(texts[start..<min(start + size, texts.count)])
            start += size
            let merged = try await mergeSummaries(batch, handle: handle)
            failed = failed || merged.failed
            if let text = merged.text { next.append(text) }
        }
        if next.count <= 1 { return (next.first, failed) }
        let final = try await mergeSummaries(next, handle: handle)
        return (final.text, failed || final.failed)
    }

    // MARK: Completion

    private enum Completion<Value: Sendable>: Sendable {
        case value(Value)
        case promptTooLong
        case failed
    }

    private enum AttemptError: Error { case truncated, malformed, timedOut }

    /// One request with the retry rules: a failure, a timeout or an answer that does not parse is tried once more
    /// (with a format reminder); an answer cut off by the token limit once more with twice the limit and is never
    /// used as it is. A prompt that does not fit the context is reported to the caller, which splits its input.
    private func complete<Value: Sendable>(
        _ handle: LLMHandle, maxTokens: Int, timeout: Duration, messages: (Bool) -> [ChatMessage],
        parse: (String) -> Value?
    ) async throws -> Completion<Value> {
        var limit = maxTokens
        var reminder = false
        var retried = false
        while true {
            try Task.checkCancellation()
            do {
                let prompt = messages(reminder)
                let tokens = limit
                let result = try await Self.withTimeout(timeout, sleep: sleep) {
                    try await handle.generateResult(messages: prompt, maxTokens: tokens)
                }
                if result.stoppedByTokenLimit { throw AttemptError.truncated }
                guard let value = parse(result.text) else { throw AttemptError.malformed }
                return .value(value)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LlamaError {
                if case .promptTooLong = error { return .promptTooLong }
                if retried { return .failed }
                retried = true
            } catch {
                try Task.checkCancellation()
                if retried { return .failed }
                retried = true
                switch error as? AttemptError {
                case .truncated?: limit *= 2
                case .malformed?: reminder = true
                default: break
                }
            }
        }
    }

    private static func withTimeout<T: Sendable>(
        _ timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await sleep(timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AttemptError.timedOut }
            guard let value = first else { throw AttemptError.timedOut }
            return value
        }
    }
}
