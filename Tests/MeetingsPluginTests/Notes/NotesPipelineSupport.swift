import Foundation
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A model that behaves like a well-mannered one: it finds the decisions, tasks and questions of a chunk by
/// keywords, quotes them word for word and organises them by id. Tests wrap or break it.
enum NotesFake {
    struct Failure: Error {}

    static func lastUser(_ messages: [ChatMessage]) -> String { messages.last?.content ?? "" }

    static func isMap(_ messages: [ChatMessage]) -> Bool {
        messages.first.map { NotesPrompt.isMapSystem($0.content) } ?? false
    }
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
    let lease: LLMLease
    /// The lease's clock (its grace period after an interactive lease): the tests move it by hand.
    let clock = NotesFakeClock()
    let url = URL(filePath: "/models/llm/test-model.gguf")
    let llm: ScriptedLLM

    init(contextLength: Int = 8192, _ handler: @escaping ScriptedLLM.Handler = NotesFake.standard) {
        let clock = clock
        lease = LLMLease(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, now: { clock.now() })
        llm = ScriptedLLM(contextLength: contextLength, handler: handler)
    }

    /// A `sleep` for the pipeline: the busy poll waits for the test (`stepper.fire()`), every other wait is real.
    func pollSleep(_ poll: Duration, _ stepper: NotesStepper) -> @Sendable (Duration) async throws -> Void {
        { duration in
            if duration == poll {
                try await stepper.sleep(duration)
            } else {
                try await Task.sleep(for: duration)
            }
        }
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

/// A clock the test moves by hand.
final class NotesFakeClock: Sendable {
    private let base = ContinuousClock.now
    private let offset = Mutex(Duration.zero)

    func now() -> ContinuousClock.Instant { base + offset.withLock { $0 } }
    func advance(_ duration: Duration) { offset.withLock { $0 += duration } }
}

/// A sleep that ends when the test says so (or when its task is cancelled).
final class NotesStepper: Sendable {
    private struct Pending {
        let id: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var next = 0
        var pending: [Pending] = []
    }

    private let state = Mutex(State())

    var pending: Int { state.withLock { $0.pending.count } }

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            state.next += 1
            return state.next
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = state.withLock { state -> Bool in
                    if Task.isCancelled { return true }
                    state.pending.append(Pending(id: id, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let entry = state.withLock { state -> Pending? in
                guard let index = state.pending.firstIndex(where: { $0.id == id }) else { return nil }
                return state.pending.remove(at: index)
            }
            entry?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Ends every sleep that is waiting.
    func fire() {
        let entries = state.withLock { state -> [Pending] in
            defer { state.pending = [] }
            return state.pending
        }
        for entry in entries { entry.continuation.resume() }
    }
}

/// Yields to the other tasks until `condition` holds (bounded; records an issue when it never does).
func spin(sourceLocation: SourceLocation = #_sourceLocation, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<200_000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("The condition was not met", sourceLocation: sourceLocation)
}
