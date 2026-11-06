import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// Collects the trace of one run.
final class NotesTraceLog: Sendable {
    private let events = Mutex<[NotesTraceEvent]>([])
    func add(_ event: NotesTraceEvent) { events.withLock { $0.append(event) } }
    var all: [NotesTraceEvent] { events.withLock { $0 } }

    var chunks: [NotesTraceChunk] {
        all.compactMap { if case .mapChunk(let chunk) = $0 { chunk } else { nil } }
    }
    var requests: [NotesTraceReduceRequest] {
        all.compactMap { if case .reduceRequest(let request) = $0 { request } else { nil } }
    }
    var points: [String: NotesTracePoint] {
        Dictionary(
            all.compactMap { if case .point(let point) = $0 { (point.id, point) } else { nil } },
            uniquingKeysWith: { first, _ in first })
    }
    var reduce: NotesTraceReduce? {
        all.lazy.compactMap { if case .reduce(let reduce) = $0 { reduce } else { nil } }.first
    }
    var summary: NotesTraceSummary? {
        all.lazy.compactMap { if case .summary(let summary) = $0 { summary } else { nil } }.first
    }
    var balance: NotesTrace.Balance { NotesTrace.balance(of: all) }
}

@Suite struct NotesTraceTests {
    private func tooLong() -> LlamaError { .promptTooLong(tokens: 9000, limit: 8192) }

    private func lineCount(_ messages: [ChatMessage]) -> Int {
        NotesFake.lastUser(messages).split(separator: "\n").filter { $0.hasPrefix("[") }.count
    }

    /// A summary point, a decision, a task, a second decision that near-duplicates the first, and a question.
    private func misfiledMeeting() -> [NotesUtterance] {
        [
            NotesUtterance(
                startMs: 5_000, speaker: "Anna",
                text: "Przejdźmy do budżetu, na marketing zostało czterdzieści tysięcy złotych."),
            NotesUtterance(startMs: 21_000, speaker: "Marek", text: "Zatwierdzamy budżet marketingu na ten kwartał."),
            NotesUtterance(startMs: 34_000, speaker: "Anna", text: "Marek wyśle ofertę do klienta do piątku."),
            NotesUtterance(
                startMs: 47_000, speaker: "Marek", text: "Zatwierdzamy budżet marketingu na ten kwartał bez zmian."),
            NotesUtterance(startMs: 60_000, speaker: "Ewa", text: "Kto zajmie się umową z dostawcą?"),
        ]
    }

    /// REDUCE lists the first decision and an unknown id, puts the question among the tasks, and leaves out the
    /// task and the second decision.
    private static let misfilingReduce: ScriptedLLM.Handler = { _, messages, _ in
        guard NotesFake.isReduce(messages) else { return .done(NotesFake.answer(messages)) }
        return .done("SUMMARY: Spotkanie dotyczyło budżetu.\nDECISIONS: p2, p99\nTASKS: p5\nQUESTIONS: -")
    }

    private struct Scenario {
        var utterances: [NotesUtterance]
        var handler: ScriptedLLM.Handler = NotesFake.standard
        var configure: @Sendable (inout NotesPipeline.Configuration) -> Void = { _ in }
    }

    private func scenarios() -> [Scenario] {
        let promptError = tooLong()
        return [
            Scenario(utterances: NotesFixtures.meeting()),
            Scenario(utterances: misfiledMeeting(), handler: Self.misfilingReduce),
            Scenario(
                utterances: NotesFixtures.meeting(),
                handler: { _, messages, _ in
                    guard NotesFake.isReduce(messages) else { return .done(NotesFake.answer(messages)) }
                    return .done(
                        "SUMMARY: Kowalski zgodził się na 50 tysięcy.\nDECISIONS: p2, p99\nTASKS: p3, p2\nQUESTIONS: p4, p1"
                    )
                }),
            Scenario(
                utterances: NotesFixtures.meeting() + NotesFixtures.filler(count: 20, startingAt: 10),
                configure: { $0.chunkTokens = 150 }),
            Scenario(utterances: decisionLines(count: 12), configure: { $0.reduceInputTokens = 60 }),
            Scenario(
                utterances: NotesFixtures.filler(count: 8),
                handler: { _, messages, _ in
                    if NotesFake.isMap(messages),
                        NotesFake.lastUser(messages).split(separator: "\n").filter({ $0.hasPrefix("[") }).count > 4
                    {
                        throw promptError
                    }
                    return .done(NotesFake.answer(messages))
                }),
            Scenario(
                utterances: NotesFixtures.meeting(),
                handler: { _, messages, _ in
                    if NotesFake.isReduce(messages) { throw NotesFake.Failure() }
                    return .done(NotesFake.answer(messages))
                }),
            Scenario(
                utterances: NotesFixtures.meeting(),
                handler: { call, messages, _ in
                    if call == 1 { return .cutOff(NotesFake.answer(messages)) }
                    return .done(NotesFake.answer(messages))
                }),
            Scenario(
                utterances: NotesFixtures.filler(count: 20),
                handler: { _, messages, _ in
                    if NotesFake.isMap(messages), NotesFake.lastUser(messages).contains("numer 7 ") {
                        throw NotesFake.Failure()
                    }
                    return .done(NotesFake.answer(messages))
                }, configure: { $0.chunkTokens = 150 }),
            Scenario(utterances: NotesFixtures.meeting(), handler: { _, _, _ in throw NotesFake.Failure() }),
            Scenario(utterances: NotesFixtures.filler(count: 3), handler: { _, _, _ in .done("NONE") }),
            Scenario(utterances: []),
        ]
    }

    private func run(_ scenario: Scenario, trace: NotesTraceLog?) async throws -> (NotesResult, [ScriptedLLM.Call]) {
        let rig = NotesRig(scenario.handler)
        var configuration = NotesPipeline.Configuration()
        scenario.configure(&configuration)
        let pipeline = NotesPipeline(
            model: rig.model, configuration: configuration,
            trace: trace.map { log -> NotesTraceSink in { log.add($0) } })
        let result = try await pipeline.run(utterances: scenario.utterances)
        return (result, rig.llm.calls)
    }

    // MARK: No change of behaviour

    @Test func theTraceChangesNeitherTheResultNorTheRequests() async throws {
        for (index, scenario) in scenarios().enumerated() {
            let log = NotesTraceLog()
            let plain = try await run(scenario, trace: nil)
            let traced = try await run(scenario, trace: log)
            #expect(plain.0 == traced.0, "scenario \(index)")
            #expect(plain.0.markdown == traced.0.markdown, "scenario \(index)")
            #expect(plain.1 == traced.1, "scenario \(index)")
            #expect(log.balance.isBalanced, "scenario \(index): \(log.balance)")
            guard case .started(let schema, _, _, _)? = log.all.first, case .finished? = log.all.last else {
                Issue.record("scenario \(index) has no start or end")
                continue
            }
            #expect(schema == NotesTrace.schemaVersion)
        }
    }

    // MARK: Codable

    @Test func theEventsOfEveryScenarioSurviveEncodingAndDecoding() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var checked = 0
        for (index, scenario) in scenarios().enumerated() {
            let log = NotesTraceLog()
            _ = try await run(scenario, trace: log)
            let data = try encoder.encode(log.all)
            let decoded = try JSONDecoder().decode([NotesTraceEvent].self, from: data)
            #expect(decoded == log.all, "scenario \(index)")
            checked += log.all.count
        }
        #expect(checked > 0)
    }

    @Test func theDropReasonsAreWrittenAsAnObjectKeyedByTheReason() throws {
        let verdict = NotesGuard.PointVerdict(verified: [], dropped: 0, reasons: [:])
        var verification = NotesTraceVerification(proposed: 0, verdict: verdict)
        verification.reasons = [.quoteTooShort: 2]
        let data = try JSONEncoder().encode(verification)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasons = try #require(object["reasons"] as? [String: Int])
        #expect(reasons == [NotesGuard.DropReason.quoteTooShort.rawValue: 2])
        #expect(try JSONDecoder().decode(NotesTraceVerification.self, from: data) == verification)
    }

    @Test func theRepairReasonsAreWrittenAsAnObjectAndAnOlderTraceHasNone() throws {
        let verdict = NotesGuard.PointVerdict(
            verified: [], dropped: 0, reasons: [:], repaired: 3, downgraded: 1,
            repairReasons: [.driftedFromQuote: 2, .downgradedQuestion: 1])
        let verification = NotesTraceVerification(proposed: 3, verdict: verdict)
        let data = try JSONEncoder().encode(verification)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reasons = try #require(object["repairReasons"] as? [String: Int])
        #expect(reasons == ["driftedFromQuote": 2, "downgradedQuestion": 1])
        #expect(try JSONDecoder().decode(NotesTraceVerification.self, from: data) == verification)

        // Schema 2 had no repair reasons.
        var older = object
        older.removeValue(forKey: "repairReasons")
        let decoded = try JSONDecoder().decode(
            NotesTraceVerification.self, from: JSONSerialization.data(withJSONObject: older))
        #expect(decoded.repairReasons.isEmpty)
        #expect(decoded.repaired == 3)
        // An unknown reason is refused, as an unknown drop reason is.
        older["repairReasons"] = ["guessed": 1]
        let unknown = try JSONSerialization.data(withJSONObject: older)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NotesTraceVerification.self, from: unknown)
        }
        #expect(NotesTrace.schemaVersion == 3)
    }

    @Test func theVerifiedEventCountsTheSummaryPointsRepairedForDrift() async throws {
        let utterances = [
            NotesUtterance(
                startMs: 0, speaker: "Mówca 1",
                text:
                    "To jest zupełnie nowa sytuacja. Tworzy się generacja programistów, którzy świata przed LLM-ami nie znają."
            ),
            NotesUtterance(startMs: 20_000, speaker: "Mówca 2", text: "Zatwierdzamy ten budżet bez zmian."),
        ]
        let handler: ScriptedLLM.Handler = { _, messages, _ in
            guard NotesFake.isMap(messages) else { return .done(NotesFake.answer(messages)) }
            return .done(
                """
                SUM | 00:00 | "tworzy się generacja programistów, którzy świata przed LLM-ami nie znają" | Nowa generacja programistów nie ma doświadczenia z LLM-ami.
                DEC | 00:20 | "Zatwierdzamy ten budżet bez zmian" | Budżet zatwierdzono bez zmian.
                """)
        }
        let log = NotesTraceLog()
        let (result, _) = try await run(Scenario(utterances: utterances, handler: handler), trace: log)
        let verified = try #require(
            log.all.lazy.compactMap { if case .verified(let v) = $0 { v } else { nil } }.first)
        #expect(verified.repaired == 1)
        #expect(verified.repairReasons == [.driftedFromQuote: 1])
        #expect(result.repairedCount == 1)
        let markdown = try #require(result.markdown)
        #expect(!markdown.contains("doświadczenia"))
        #expect(markdown.contains("Budżet zatwierdzono bez zmian."))
        #expect(log.balance.isBalanced)
    }

    // MARK: Fates

    @Test func aMisfiledAndAnOmittedPointAreAccountedForWithTheirReasons() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(
            Scenario(utterances: misfiledMeeting(), handler: Self.misfilingReduce), trace: log)

        #expect(result.verifiedPointCount == 5)
        #expect(result.rejectedIDs == 2)
        #expect(result.backfilledCount == 2)
        let points = log.points
        #expect(points["p1"]?.fate == .rendered(.keyPoints, via: .listedByCode))
        #expect(points["p2"]?.fate == .rendered(.decisions, via: .reduce))
        #expect(points["p3"]?.fate == .rendered(.tasks, via: .backfilled))
        #expect(points["p4"]?.fate == .notRendered(.nearDuplicateInSection(of: "p2")))
        #expect(points["p5"]?.fate == .rendered(.questions, via: .backfilled))
        #expect(points["p5"]?.misfiledInto == [.tasks])
        #expect(points["p4"]?.timeMs == 47_000)
        #expect(points["p4"]?.kind == .decision)

        let balance = log.balance
        #expect(balance.isBalanced)
        #expect(balance.verified == 5)
        #expect(balance.rendered == 4)
        #expect(balance.notRendered == 1)

        let reduce = try #require(log.reduce)
        #expect(reduce.rejectedIDs == 2)
        #expect(reduce.rejectedUnknown == 1)
        #expect(reduce.rejectedWrongSection == 1)
        #expect(reduce.backfilled == 2)
        #expect(reduce.nearDuplicatesSkipped == 1)
        #expect(reduce.decisions == 1 && reduce.tasks == 1 && reduce.questions == 1)
        #expect(reduce.keyPoints == 1)
        #expect(reduce.batches == 1 && reduce.sectionRequests == 1 && !reduce.reduceFailed)
        #expect(log.summary == NotesTraceSummary(origin: .model, present: true, shown: true, sourceIDs: []))
        #expect(log.all.last == .finished(status: .ok, verified: 5, rendered: 4, notRendered: 1))

        // The composer shows what the trace says it shows.
        let markdown = try #require(result.markdown)
        #expect(markdown.contains("### Kluczowe punkty"))
        #expect(markdown.contains("Zatwierdzamy budżet marketingu na ten kwartał."))
        #expect(!markdown.contains("bez zmian"))
    }

    @Test func aRefusedSummaryIsComposedFromTheSummaryPoints() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(scenarios()[2], trace: log)
        #expect(result.summaryReplaced)
        let summary = try #require(log.summary)
        #expect(summary.origin == .composedAfterRefusal)
        #expect(summary.shown)
        #expect(summary.sourceIDs == ["p1"])
        #expect(summary.sourceStartMs == 5_000 && summary.sourceEndMs == 5_000)
        let points = log.points
        #expect(points["p1"]?.fate == .rendered(.summary, via: .composedSummary))
        #expect(points["p1"]?.misfiledInto == [.questions])
        #expect(points["p2"]?.misfiledInto == [.tasks])
        #expect(log.reduce?.rejectedUnknown == 1)
        #expect(log.reduce?.rejectedWrongSection == 2)
        #expect(log.balance.isBalanced)
    }

    @Test func overlappingChunksShowTheDeduplication() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(scenarios()[3], trace: log)
        let removed = log.all.compactMap { event -> [String]? in
            if case .deduplicated(let removed, _) = event { removed } else { nil }
        }.first
        let verified = log.all.compactMap { if case .verified(let v) = $0 { v } else { nil } }.first
        #expect(!(removed ?? []).isEmpty)
        #expect((verified?.verified.total ?? 0) - (removed?.count ?? 0) == result.verifiedPointCount)
        #expect(log.chunks.count == result.chunkCount)
        #expect(log.chunks.map(\.chunkID) == (1...result.chunkCount).map { "c\($0)" })
        // The numbers of the proposed points follow each other across chunks.
        var next = 1
        for chunk in log.chunks {
            #expect(chunk.firstPointNumber == next)
            next += chunk.proposed.total
        }
        #expect(log.balance.isBalanced)
    }

    @Test func manyReduceBatchesAndMergesAreCounted() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(scenarios()[4], trace: log)
        let reduce = try #require(log.reduce)
        #expect(reduce.batches > 3)
        #expect(reduce.sectionRequests == log.requests.filter { $0.stage == .sections }.count)
        #expect(reduce.summaryMergeRequests >= 1)
        #expect(log.points.values.allSatisfy { $0.fate == .rendered(.decisions, via: .reduce) })
        #expect(log.points.count == result.verifiedPointCount)
        #expect(log.balance.isBalanced)
    }

    @Test func aFailedReduceRendersEveryPointInCodeOrder() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(scenarios()[6], trace: log)
        #expect(result.reduceFailed)
        let request = try #require(log.requests.first)
        #expect(request.outcome == .codeOrder)
        #expect(request.attempts.requests == 2 && request.attempts.errors == 2)
        #expect(request.pointIDs == ["p1", "p2", "p3", "p4"])
        #expect(log.reduce?.codeOrderBatches == 1)
        #expect(log.reduce?.reduceFailed == true)
        #expect(log.summary?.origin == .composedWithoutModelParagraph)
        let points = log.points
        #expect(points["p1"]?.fate == .rendered(.summary, via: .composedSummary))
        #expect(points["p2"]?.fate == .rendered(.decisions, via: .codeOrder))
        #expect(points["p3"]?.fate == .rendered(.tasks, via: .codeOrder))
        #expect(points["p4"]?.fate == .rendered(.questions, via: .codeOrder))
        #expect(log.balance.isBalanced)
    }

    // MARK: Key points

    /// Six utterances with nothing in common but the language: a podcast, where MAP finds summary points only.
    private func podcast() -> [NotesUtterance] {
        [
            NotesUtterance(
                startMs: 5_000, speaker: "Anna",
                text: "Przejdźmy do budżetu, na marketing zostało czterdzieści tysięcy złotych."),
            NotesUtterance(
                startMs: 20_000, speaker: "Marek", text: "Kampania w telewizji kosztowała więcej niż zakładaliśmy."),
            NotesUtterance(startMs: 40_000, speaker: "Ewa", text: "Klienci chwalą nową aplikację mobilną."),
            NotesUtterance(startMs: 60_000, speaker: "Piotr", text: "Konkurencja obniżyła ceny w zeszłym miesiącu."),
            NotesUtterance(startMs: 80_000, speaker: "Anna", text: "Zespół sprzedaży potrzebuje dwóch nowych osób."),
            NotesUtterance(
                startMs: 100_000, speaker: "Marek", text: "Serwer produkcyjny działał stabilnie przez cały kwartał."),
        ]
    }

    /// MAP gives a summary point for every line and one more whose quote nobody said (the last, so `p7`);
    /// REDUCE lists nothing and writes `paragraph`.
    private static func summaryOnly(paragraph: String) -> ScriptedLLM.Handler {
        { _, messages, _ in
            if NotesFake.isMap(messages) {
                var lines = NotesFake.transcriptLines(messages).map { line in
                    let quote = line.text.trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
                    return "SUM | \(line.time) | \"\(quote)\" | \(quote)."
                }
                lines.append("SUM | 00:30 | \"Zarząd zatwierdził fuzję z konkurencją\" | Zarząd zatwierdził fuzję.")
                return .done(lines.joined(separator: "\n"))
            }
            if NotesFake.isReduce(messages) {
                return .done("SUMMARY: \(paragraph)\nDECISIONS: -\nTASKS: -\nQUESTIONS: -")
            }
            return .done(NotesFake.answer(messages))
        }
    }

    /// The bullets under the key points heading, in order.
    private static func keyPointLines(_ markdown: String) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "### Kluczowe punkty") else { return [] }
        return Array(lines[(start + 1)...].drop { $0.isEmpty }.prefix { $0.hasPrefix("- ") })
    }

    @Test func summaryPointsOnlyAreAllShownAsKeyPointsInTimeOrder() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(
            Scenario(utterances: podcast(), handler: Self.summaryOnly(paragraph: "Spotkanie dotyczyło budżetu.")),
            trace: log)
        #expect(result.status == .ok)
        #expect(result.droppedCount == 1)
        #expect(result.verifiedPointCount == 6)
        #expect(result.keyPoints.map(\.id) == ["p1", "p2", "p3", "p4", "p5", "p6"])
        #expect(result.points.isEmpty)
        let markdown = try #require(result.markdown)
        #expect(
            Self.keyPointLines(markdown) == [
                "- Przejdźmy do budżetu, na marketing zostało czterdzieści tysięcy złotych. \\[00\\:05\\]",
                "- Kampania w telewizji kosztowała więcej niż zakładaliśmy. \\[00\\:20\\]",
                "- Klienci chwalą nową aplikację mobilną. \\[00\\:40\\]",
                "- Konkurencja obniżyła ceny w zeszłym miesiącu. \\[01\\:00\\]",
                "- Zespół sprzedaży potrzebuje dwóch nowych osób. \\[01\\:20\\]",
                "- Serwer produkcyjny działał stabilnie przez cały kwartał. \\[01\\:40\\]",
            ])
        #expect(!markdown.contains("fuzj"))
        #expect(!markdown.contains("### Decyzje"))
        #expect(log.summary?.origin == .model)
        #expect(log.points.values.allSatisfy { $0.fate == .rendered(.keyPoints, via: .listedByCode) })
        #expect(log.reduce?.keyPoints == 6)
        let balance = log.balance
        #expect(balance.isBalanced)
        #expect(balance.verified == 6 && balance.rendered == 6 && balance.notRendered == 0 && balance.unexplained == 0)
    }

    /// The measured case: the model's paragraph is refused, the code composes it from the first four summary
    /// points, and the others stand as key points; nothing is said twice and nothing is lost.
    @Test func aRefusedParagraphLeavesTheOtherSummaryPointsAsKeyPoints() async throws {
        let log = NotesTraceLog()
        let (result, _) = try await run(
            Scenario(
                utterances: podcast(), handler: Self.summaryOnly(paragraph: "Kowalski zgodził się na 50 tysięcy.")),
            trace: log)
        #expect(result.summaryReplaced)
        #expect(log.summary?.origin == .composedAfterRefusal)
        #expect(log.summary?.sourceIDs == ["p1", "p2", "p3", "p4"])
        #expect(result.keyPoints.map(\.id) == ["p5", "p6"])
        let markdown = try #require(result.markdown)
        #expect(
            Self.keyPointLines(markdown) == [
                "- Zespół sprzedaży potrzebuje dwóch nowych osób. \\[01\\:20\\]",
                "- Serwer produkcyjny działał stabilnie przez cały kwartał. \\[01\\:40\\]",
            ])
        #expect(markdown.components(separatedBy: "Klienci chwalą nową aplikację mobilną.").count == 2)
        #expect(!markdown.contains("fuzj"))
        let points = log.points
        for id in ["p1", "p2", "p3", "p4"] {
            #expect(points[id]?.fate == .rendered(.summary, via: .composedSummary), "\(id)")
        }
        for id in ["p5", "p6"] { #expect(points[id]?.fate == .rendered(.keyPoints, via: .listedByCode), "\(id)") }
        #expect(!points.values.contains { $0.fate == .notRendered(.summaryKindNotInComposedParagraph) })
        let balance = log.balance
        #expect(balance.isBalanced)
        #expect(balance.verified == 6 && balance.rendered == 6 && balance.unexplained == 0)
        #expect(log.all.last == .finished(status: .ok, verified: 6, rendered: 6, notRendered: 0))
    }

    // MARK: Attempts

    @Test func aCutOffAnswerShowsTheRetryAndTheLargerLimit() async throws {
        let log = NotesTraceLog()
        _ = try await run(scenarios()[7], trace: log)
        let chunk = try #require(log.chunks.first)
        #expect(chunk.outcome == .points)
        #expect(chunk.attempts.requests == 2)
        #expect(chunk.attempts.retried)
        #expect(chunk.attempts.truncated == 1)
        #expect(chunk.attempts.firstMaxTokens == 1000)
        #expect(chunk.attempts.lastMaxTokens == 2000)
        #expect(chunk.attempts.promptTokens > chunk.estimatedTokens)
        #expect(chunk.startMs == 5_000 && chunk.endMs == 47_000 && chunk.utterances == 4)
        #expect(chunk.proposed.summary == 1 && chunk.proposed.decision == 1)
        #expect(chunk.proposed.task == 1 && chunk.proposed.question == 1)
    }

    @Test func aReduceCutOffTwiceIsCountedAsTruncated() async throws {
        let log = NotesTraceLog()
        let scenario = Scenario(
            utterances: NotesFixtures.meeting(),
            handler: { _, messages, _ in
                if NotesFake.isReduce(messages) { return .cutOff(NotesFake.answer(messages)) }
                return .done(NotesFake.answer(messages))
            })
        _ = try await run(scenario, trace: log)
        let request = try #require(log.requests.first)
        #expect(request.outcome == .codeOrder)
        #expect(request.attempts.truncated == 2)
        #expect(request.attempts.firstMaxTokens == 1500 && request.attempts.lastMaxTokens == 3000)
        #expect(log.reduce?.truncatedAnswers == 2)
        #expect(log.reduce?.generationRequests == 2)
    }

    @Test func aMalformedAnswerIsCountedOnce() async throws {
        let log = NotesTraceLog()
        let scenario = Scenario(
            utterances: NotesFixtures.meeting(),
            handler: { call, messages, _ in
                if call == 1 { return .done("Oto podsumowanie spotkania: rozmawiano o budżecie.") }
                return .done(NotesFake.answer(messages))
            })
        _ = try await run(scenario, trace: log)
        let chunk = try #require(log.chunks.first)
        #expect(chunk.attempts.malformed == 1 && chunk.attempts.requests == 2 && chunk.outcome == .points)
    }

    @Test func aSplitChunkIsFollowedByItsHalves() async throws {
        let log = NotesTraceLog()
        _ = try await run(scenarios()[5], trace: log)
        let chunks = log.chunks
        #expect(chunks.map(\.chunkID) == ["c1", "c1.1", "c1.2"])
        #expect(chunks.map(\.outcome) == [.split, .points, .points])
        #expect(chunks[0].attempts.promptTooLong)
        #expect(chunks[0].utterances == 8 && chunks[1].utterances == 4 && chunks[2].utterances == 4)
        #expect(chunks[1].firstPointNumber == 1)
        #expect(chunks[2].firstPointNumber == 1 + chunks[1].proposed.total)
    }

    @Test func failedAndEmptyRunsEndWithNothingToAccountFor() async throws {
        let failing = NotesTraceLog()
        _ = try await run(scenarios()[9], trace: failing)
        #expect(failing.chunks.map(\.outcome) == [.failed])
        #expect(failing.all.last == .finished(status: .failed, verified: 0, rendered: 0, notRendered: 0))
        #expect(failing.balance.isBalanced)

        let empty = NotesTraceLog()
        _ = try await run(scenarios()[11], trace: empty)
        #expect(
            empty.all == [
                .started(
                    schemaVersion: NotesTrace.schemaVersion, promptVersion: NotesPrompt.version, utterances: 0,
                    chunks: 0),
                .finished(status: .ok, verified: 0, rendered: 0, notRendered: 0),
            ])
    }

    @Test func theBalanceFindsAPointWithoutAFate() {
        let point = NotesTracePoint(
            id: "p1", kind: .decision, proposedKind: .decision, timeMs: 0, misfiledInto: [],
            fate: .rendered(.decisions, via: .reduce))
        let unexplained = NotesTracePoint(
            id: "p3", kind: .task, proposedKind: .task, timeMs: 0, misfiledInto: [], fate: .notRendered(.unexplained))
        let balance = NotesTrace.balance(of: [
            .deduplicated(removedIDs: [], keptIDs: ["p1", "p2", "p3"]), .point(point), .point(point),
            .point(unexplained),
        ])
        #expect(!balance.isBalanced)
        #expect(balance.missingIDs == ["p2"])
        #expect(balance.unexpectedIDs == ["p1"])
        #expect(balance.unexplained == 1)
    }

    // MARK: Privacy

    @Test func theTraceHoldsNoWordOfTheTranscriptOrOfTheModel() async throws {
        var words = Set<String>()
        var described: [String] = []
        for scenario in scenarios() {
            let log = NotesTraceLog()
            let (result, calls) = try await run(scenario, trace: log)
            for utterance in scenario.utterances {
                words.formUnion(Self.words(utterance.text))
                words.formUnion(Self.words(utterance.speaker))
            }
            // The points' texts and the paragraph the model wrote end up in the notes.
            words.formUnion(Self.words(result.markdown ?? ""))
            for call in calls { words.formUnion(Self.words(NotesFake.answer(call.messages))) }
            for event in log.all {
                described.append(String(describing: event))
                described.append(String(reflecting: event))
            }
        }
        // What the scripted REDUCE answers above wrote.
        words.formUnion(Self.words("Spotkanie dotyczyło budżetu. Kowalski zgodził się na 50 tysięcy."))
        // The headings and labels of the notes are the code's, not the transcript's.
        words.subtract(Self.words("Podsumowanie Decyzje Zadania Otwarte pytania Uczestnicy osoba termin summary"))
        // The line codes and keys of the answer format, and the letters of the ids (`p12`, `c3`).
        words.subtract(["sum", "dec", "task", "ask", "none", "decisions", "tasks", "questions", "p", "c"])
        #expect(!words.isEmpty)
        let traced = Set(described.flatMap { Self.words($0) })
        // The descriptions are the events' fields (the test would pass on empty strings otherwise).
        #expect(traced.isSuperset(of: ["chunkid", "firstpointnumber", "nearduplicateinsection", "misfiledinto"]))
        let leaked = words.intersection(traced)
        #expect(leaked.isEmpty, "trace words found in the transcript or the model's text: \(leaked.sorted())")
    }

    /// Runs of letters, lower-cased (`nearDuplicateInSection` is one word, as in the descriptions).
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init))
    }
}
