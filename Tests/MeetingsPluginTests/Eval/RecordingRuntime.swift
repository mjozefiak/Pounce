import Foundation
import LintelSpeech
import Synchronization

@testable import MeetingsPlugin

/// Wraps a real `LLMRuntime` and remembers every completion it made, so the evaluation can explain afterwards why
/// the guard refused a point. Test-only: the app never records what the model said. The records are written only
/// into the evaluation's own output folder and only when `LINTEL_MEETING_EVAL_DUMP_REJECTIONS=1`.
final class RecordingRuntime: LLMRuntime {
    struct Record: Equatable, Sendable {
        var isMap: Bool
        var maxTokens: Int
        var response: String
        var stoppedByTokenLimit: Bool
    }

    private let inner: any LLMRuntime
    private let storage = Mutex<[Record]>([])

    init(_ inner: any LLMRuntime) { self.inner = inner }

    var records: [Record] { storage.withLock { $0 } }

    var contextLength: Int { inner.contextLength }
    var isLoaded: Bool { get async { await inner.isLoaded } }

    func load(modelAt url: URL) async throws { try await inner.load(modelAt: url) }
    func unload() async { await inner.unload() }

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await generateResult(messages: messages, maxTokens: maxTokens).text
    }

    func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        let result = try await inner.generateResult(messages: messages, maxTokens: maxTokens)
        let isMap = messages.first.map { NotesPrompt.isMapSystem($0.content) } ?? false
        storage.withLock {
            $0.append(
                Record(
                    isMap: isMap, maxTokens: maxTokens, response: result.text,
                    stoppedByTokenLimit: result.stoppedByTokenLimit))
        }
        return result
    }
}

/// Why the guard refused or repaired each point of each MAP answer, with the texts needed to see it. The file
/// holds transcript-derived text, so it stays in the evaluation's output folder (mode 0600); stdout and the
/// trace get numbers only.
struct NotesRejectionReport: Codable, Equatable {
    struct Point: Codable, Equatable {
        var kind: String
        /// `verified`, `repaired:<reason>` or `dropped:<reason>`.
        var outcome: String
        var textLength: Int
        var quoteLength: Int
        var textLanguage: String
        var quoteLanguage: String
        var textHasMowca: Bool
        var quoteHasMowca: Bool
        var text: String
        var quote: String
    }

    struct Answer: Codable, Equatable {
        var maxTokens: Int
        var stoppedByTokenLimit: Bool
        var malformed: Bool
        var response: String
        var points: [Point]
    }

    var schema = 1
    var recording: String
    var answers: [Answer]

    var pointCount: Int { answers.reduce(0) { $0 + $1.points.count } }
    var rejectedCount: Int {
        answers.reduce(0) { total, answer in total + answer.points.filter { $0.outcome != "verified" }.count }
    }

    static func language(_ language: NotesLanguage) -> String {
        switch language {
        case .polish: "polish"
        case .english: "english"
        case .unknown: "unknown"
        }
    }

    static func build(recording: String, records: [RecordingRuntime.Record], utterances: [NotesUtterance]) -> Self {
        let guardrail = NotesGuard(utterances: utterances)
        let answers = records.filter(\.isMap).map { record -> Answer in
            var malformed = false
            var parsed: [NotesPoint] = []
            switch NotesParser.parseMap(record.response) {
            case .points(let points): parsed = points
            case .malformed: malformed = true
            }
            let points = parsed.map { point -> Point in
                let verdict = guardrail.verifyPoints([point])
                let outcome: String
                if let reason = verdict.reasons.keys.first {
                    outcome = "dropped:\(reason.rawValue)"
                } else if let reason = verdict.repairReasons.keys.first {
                    outcome = "repaired:\(reason.rawValue)"
                } else {
                    outcome = "verified"
                }
                return Point(
                    kind: point.kind.rawValue, outcome: outcome, textLength: point.text.count,
                    quoteLength: point.quote.count,
                    textLanguage: language(NotesLanguage.dominant(in: point.text)),
                    quoteLanguage: language(NotesLanguage.dominant(in: point.quote)),
                    textHasMowca: point.text.localizedCaseInsensitiveContains("Mówca"),
                    quoteHasMowca: point.quote.localizedCaseInsensitiveContains("Mówca"),
                    text: point.text, quote: point.quote)
            }
            return Answer(
                maxTokens: record.maxTokens, stoppedByTokenLimit: record.stoppedByTokenLimit, malformed: malformed,
                response: record.response, points: points)
        }
        return Self(recording: recording, answers: answers)
    }

    /// Writes `<directory>/<recording>.notes-rejections.json` only when `enabled`; returns its URL, or nil.
    @discardableResult
    static func writeIfEnabled(
        _ enabled: Bool, recording: String, records: [RecordingRuntime.Record], utterances: [NotesUtterance],
        to directory: URL
    ) throws -> (url: URL, report: Self)? {
        guard enabled else { return nil }
        let report = build(recording: recording, records: records, utterances: utterances)
        return (try EvalResultWriter.write(report, to: directory), report)
    }
}
