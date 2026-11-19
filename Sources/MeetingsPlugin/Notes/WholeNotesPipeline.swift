import Foundation
import LintelSpeech

/// The whole-transcript track (`NotesStrategy.wholeTranscript`): one generation over the whole transcript, the
/// model writes the notes in the line format, the code checks the facts (`NotesFactGuard`) and composes the Markdown.
///
/// A transcript above the generator's input budget is cut between utterances into parts of at most `partTokens`,
/// every part gets a draft, and one merge request writes the final notes; the guard then checks the final notes
/// against the whole transcript. More than `maxParts` parts end the job with `NotesFailure.transcriptTooLong`
/// before any request is made. A request that fails after its one retry ends the whole job as `failed`: this track
/// never writes `partial` notes (a part of a meeting would read as the whole).
///
/// Nothing here logs; the result carries counters only. Nothing calls this track in the app yet.
struct WholeNotesPipeline: Sendable {
    struct Configuration: Sendable {
        /// The estimated tokens of one part of a long meeting (spec Q12; working numbers).
        var partTokens = 40_000
        var maxParts = 8
        var answerMaxTokens = 4000
        var timeout: Duration = .seconds(600)
        var fallbackLanguage: NotesLanguage = .english
        init() {}
    }

    private enum AttemptError: Error { case unusable }

    let generator: any NotesGenerating
    let configuration: Configuration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        generator: any NotesGenerating, configuration: Configuration = Configuration(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.generator = generator
        self.configuration = configuration
        self.sleep = sleep
    }

    /// Writes the notes. Throws `CancellationError` when cancelled, `NotesFailure.transcriptTooLong` for a too long
    /// transcript, and whatever the generator throws that is not a plain failed attempt (for example a refused
    /// authorisation); a failed attempt is `status: .failed`.
    func run(
        utterances: [NotesUtterance], durationMs: Int? = nil,
        onEvent: @escaping @Sendable (NotesEvent) -> Void = { _ in }
    ) async throws -> NotesResult {
        let language = NotesLanguage.dominant(in: utterances.map(\.text).joined(separator: " "))
        func result(
            _ status: NotesResult.Status, markdown: String? = nil, dropped: Int = 0, parts: Int = 0
        ) -> NotesResult {
            NotesResult(
                status: status, markdown: markdown, droppedCount: dropped, failedChunks: [], chunkCount: parts,
                verifiedPointCount: 0, reduceFailed: false, summaryReplaced: false, rejectedIDs: 0,
                language: language, promptVersion: WholeNotesPrompt.version)
        }
        guard !utterances.isEmpty else { return result(.ok) }

        let budget = generator.profile.inputBudgetTokens
        let parts = Self.parts(of: utterances, budget: budget, partTokens: configuration.partTokens)
        if parts.count > configuration.maxParts { throw NotesFailure.transcriptTooLong }

        try Task.checkCancellation()
        try await generator.open()
        do {
            let final: NotesDraft?
            if parts.count == 1 {
                let transcript = WholeNotesPrompt.transcriptLines(utterances)
                final = try await write {
                    WholeNotesPrompt.messages(transcript: transcript, language: language, reminder: $0)
                }
            } else {
                var drafts: [String] = []
                for (index, part) in parts.enumerated() {
                    onEvent(.map(done: index, total: parts.count + 1))
                    let messages = { (reminder: Bool) in
                        WholeNotesPrompt.messages(
                            transcript: WholeNotesPrompt.transcriptLines(part), language: language,
                            part: (index + 1, parts.count), reminder: reminder)
                    }
                    guard let draft = try await write(messages) else {
                        await generator.release()
                        return result(.failed, parts: parts.count)
                    }
                    drafts.append(draft.lines)
                }
                onEvent(.map(done: parts.count, total: parts.count + 1))
                final = try await write({ WholeNotesPrompt.mergeMessages(drafts: drafts, reminder: $0) })
            }
            await generator.release()
            onEvent(.finishing)
            guard let final else { return result(.failed, parts: parts.count) }
            let checked = NotesFactGuard(utterances: utterances, durationMs: durationMs).check(final)
            guard !checked.draft.isEmpty else {
                return result(.failed, dropped: checked.report.dropped, parts: parts.count)
            }
            let labels = NotesComposer.Labels.forLanguage(language, fallback: configuration.fallbackLanguage)
            let markdown = NotesDraftComposer.markdown(
                draft: checked.draft, participants: NotesPipeline.participants(of: utterances), labels: labels)
            return result(.ok, markdown: markdown, dropped: checked.report.dropped, parts: parts.count)
        } catch {
            await generator.release()
            throw error
        }
    }

    /// One request with the one retry of the track: a thrown error that is not a cancellation or a refusal, a
    /// timeout, a cut-off answer, or an answer with neither summary nor item is a failed attempt. The retry carries
    /// a format reminder. `nil` after the second failed attempt.
    private func write(_ messages: (Bool) -> [ChatMessage]) async throws -> NotesDraft? {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let prompt = messages(attempt > 0)
            let maxTokens = configuration.answerMaxTokens
            let generator = generator
            do {
                let generated = try await NotesDeadline.run(limit: configuration.timeout, sleep: sleep) { phase in
                    try await generator.generateResult(messages: prompt, maxTokens: maxTokens, onPhase: phase)
                }
                guard let generated, !generated.stoppedByTokenLimit else { continue }
                let parsed = NotesDraftParser.parse(generated.text)
                guard parsed.isUsable else { continue }
                return parsed.draft
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as NotesFailure {
                throw error
            } catch let error as NotesGenerationRefusal {
                throw error
            } catch {
                try Task.checkCancellation()
                continue
            }
        }
        return nil
    }

    // MARK: Parts

    /// The transcript in one part when it fits `budget`; else parts of at most `partTokens`, cut between utterances
    /// at the longest pause near the limit, without overlap.
    static func parts(of utterances: [NotesUtterance], budget: Int, partTokens: Int) -> [[NotesUtterance]] {
        func tokens(_ utterance: NotesUtterance) -> Int {
            NotesText.estimateTokens(WholeNotesPrompt.transcriptLines([utterance]), fallback: .unknown) + 2
        }
        let costs = utterances.map(tokens)
        guard costs.reduce(0, +) > budget else { return [utterances] }
        var result: [[NotesUtterance]] = []
        var start = 0
        while start < utterances.count {
            var end = start
            var used = 0
            while end < utterances.count, used + costs[end] <= partTokens || end == start {
                used += costs[end]
                end += 1
            }
            if end < utterances.count {
                // The longest pause among the last fifth of the part.
                let from = max(start + 1, end - max(1, (end - start) / 5))
                var best = end
                var bestGap = -1
                for cut in from...end where cut < utterances.count {
                    let gap = utterances[cut].startMs - utterances[cut - 1].startMs
                    if gap > bestGap {
                        bestGap = gap
                        best = cut
                    }
                }
                end = best
            }
            result.append(Array(utterances[start..<end]))
            start = end
        }
        return result
    }
}

/// A generator refuses to start a request (authorisation withdrawn, say). Never a failed attempt: it ends the job
/// at once, with no retry and no partial notes.
struct NotesGenerationRefusal: Error, Equatable {}
