import Foundation
import PounceSpeech
import Synchronization

@testable import MeetingsPlugin

/// A model that behaves like a well-mannered one: it finds the decisions, tasks and questions of a chunk by
/// keywords, quotes them word for word and organises them by id. Tests wrap or break it.
enum NotesFake {
    struct Failure: Error {}

    static func lastUser(_ messages: [ChatMessage]) -> String { messages.last?.content ?? "" }

    static func isMap(_ messages: [ChatMessage]) -> Bool { messages.first?.content == NotesPrompt.mapSystem }
    static func isReduce(_ messages: [ChatMessage]) -> Bool { messages.first?.content == NotesPrompt.reduceSystem }
    static func isSummary(_ messages: [ChatMessage]) -> Bool { messages.first?.content == NotesPrompt.summarySystem }

    /// The `[mm:ss] Speaker: text` lines of the request.
    static func transcriptLines(_ messages: [ChatMessage]) -> [(time: String, text: String)] {
        lastUser(messages).split(separator: "\n").compactMap { line in
            guard let match = line.firstMatch(of: /^\[(\d+:\d\d)\] [^:]+: (.+)$/) else { return nil }
            return (String(match.1), String(match.2))
        }
    }

    static func mapAnswer(_ messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for (index, line) in transcriptLines(messages).enumerated() {
            let quote = line.text.trimmingCharacters(in: CharacterSet(charactersIn: ".?!"))
            let lower = line.text.lowercased()
            if lower.contains("zatwierdzamy") {
                lines.append("DEC | \(line.time) | \"\(quote)\" | Ustalono: \(quote).")
            } else if lower.contains("wyśle") {
                lines.append("TASK | \(line.time) | \"\(quote)\" | Do zrobienia: \(quote). | Marek | piątek")
            } else if line.text.contains("?") {
                lines.append("ASK | \(line.time) | \"\(quote)\" | \(quote)?")
            } else if index == 0 {
                lines.append("SUM | \(line.time) | \"\(quote)\" | \(quote).")
            }
        }
        return lines.isEmpty ? "NONE" : lines.joined(separator: "\n")
    }

    static func reduceAnswer(_ messages: [ChatMessage], summary: String? = nil) -> String {
        var decisions: [String] = []
        var tasks: [String] = []
        var questions: [String] = []
        var firstSummary: String?
        for line in lastUser(messages).split(separator: "\n") {
            guard let match = line.firstMatch(of: /^(p\d+) \[(\w+)\] (.*)$/) else { continue }
            switch match.2 {
            case "DEC": decisions.append(String(match.1))
            case "TASK": tasks.append(String(match.1))
            case "ASK": questions.append(String(match.1))
            case "SUM": firstSummary = firstSummary ?? String(match.3)
            default: break
            }
        }
        let paragraph =
            summary ?? firstSummary.map { NotesText.firstSentence($0) } ?? "Spotkanie dotyczyło kilku spraw."
        func list(_ ids: [String]) -> String { ids.isEmpty ? "-" : ids.joined(separator: ", ") }
        return
            "SUMMARY: \(paragraph)\nDECISIONS: \(list(decisions))\nTASKS: \(list(tasks))\nQUESTIONS: \(list(questions))"
    }

    static func answer(_ messages: [ChatMessage]) -> String {
        if isMap(messages) { return mapAnswer(messages) }
        if isReduce(messages) { return reduceAnswer(messages) }
        return "SUMMARY: Spotkanie dotyczyło zatwierdzania punktów harmonogramu."
    }

    static var standard: ScriptedLLM.Handler {
        { _, messages, _ in .done(answer(messages)) }
    }
}

final class NotesEventLog: @unchecked Sendable {
    private let events = Mutex<[NotesEvent]>([])
    func add(_ event: NotesEvent) { events.withLock { $0.append(event) } }
    var all: [NotesEvent] { events.withLock { $0 } }
}

/// A flag a test sets from inside a model closure.
final class Flag: @unchecked Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    func clear() { value.withLock { $0 = false } }
    var isSet: Bool { value.withLock { $0 } }
}

struct NotesRig {
    let lease = LLMLease(sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    let url = URL(filePath: "/models/llm/test-model.gguf")
    let llm: ScriptedLLM

    init(contextLength: Int = 8192, _ handler: @escaping ScriptedLLM.Handler = NotesFake.standard) {
        llm = ScriptedLLM(contextLength: contextLength, handler: handler)
    }

    var model: NotesModel { NotesModel(lease: lease, runtime: llm, modelURL: url) }

    func pipeline(
        _ configure: (inout NotesPipeline.Configuration) -> Void = { _ in },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> NotesPipeline {
        var configuration = NotesPipeline.Configuration()
        configure(&configuration)
        return NotesPipeline(model: model, configuration: configuration, sleep: sleep)
    }

    /// Waits for the lease to be given back.
    func waitUntilReleased() async -> Bool {
        for _ in 0..<300 {
            if await lease.activeLeases == 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

/// `count` lines that the fake model reads as decisions.
func decisionLines(count: Int) -> [NotesUtterance] {
    (0..<count).map {
        NotesUtterance(
            startMs: $0 * 10_000, speaker: "Anna", text: "Zatwierdzamy punkt numer \($0) harmonogramu projektu.")
    }
}
