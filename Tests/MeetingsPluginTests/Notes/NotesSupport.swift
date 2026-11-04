import Foundation
import LintelSpeech
import Synchronization

@testable import MeetingsPlugin

/// A Polish meeting of four utterances: a fact, a decision, a task with a person and a weekday, a question.
enum NotesFixtures {
    static func meeting() -> [NotesUtterance] {
        [
            NotesUtterance(
                startMs: 5_000, speaker: "Anna",
                text: "Przejdźmy do budżetu, na marketing zostało czterdzieści tysięcy złotych."),
            NotesUtterance(startMs: 21_000, speaker: "Marek", text: "Zatwierdzamy ten budżet bez zmian."),
            NotesUtterance(startMs: 34_000, speaker: "Anna", text: "Marek wyśle ofertę do klienta do piątku."),
            NotesUtterance(startMs: 47_000, speaker: "Ewa", text: "Kto zajmie się umową z dostawcą?"),
        ]
    }

    /// `count` plain utterances of about twelve Polish words each.
    static func filler(count: Int, startingAt first: Int = 0) -> [NotesUtterance] {
        (0..<count).map { index in
            let number = first + index
            return NotesUtterance(
                startMs: number * 10_000, speaker: number.isMultiple(of: 2) ? "Anna" : "Marek",
                text: "Omawiamy punkt numer \(number) agendy i jego wpływ na harmonogram projektu w tym kwartale.")
        }
    }
}

/// A language model that answers with a closure, and records every request. Cancelling the calling task
/// stops a closure that waits with `Task.sleep`, like a decode loop does between two tokens.
final class ScriptedLLM: LLMRuntime, @unchecked Sendable {
    typealias Handler =
        @Sendable (_ call: Int, _ messages: [ChatMessage], _ maxTokens: Int) async throws ->
        GenerationResult

    struct Call: Equatable, Sendable {
        var messages: [ChatMessage]
        var maxTokens: Int
    }

    private struct State {
        var loaded = false
        var calls: [Call] = []
        var loadFails = false
    }

    struct LoadFailure: Error {}

    let contextLength: Int
    private let state = Mutex(State())
    private let handler: Handler

    init(contextLength: Int = 8192, handler: @escaping Handler) {
        self.contextLength = contextLength
        self.handler = handler
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var isLoaded: Bool { state.withLock { $0.loaded } }

    func failLoading() { state.withLock { $0.loadFails = true } }

    func load(modelAt url: URL) async throws {
        if state.withLock({ $0.loadFails }) { throw LoadFailure() }
        state.withLock { $0.loaded = true }
    }

    func unload() async { state.withLock { $0.loaded = false } }

    func generate(messages: [ChatMessage], maxTokens: Int) async throws -> String {
        try await generateResult(messages: messages, maxTokens: maxTokens).text
    }

    func generateResult(messages: [ChatMessage], maxTokens: Int) async throws -> GenerationResult {
        let call = state.withLock { state -> Int in
            state.calls.append(Call(messages: messages, maxTokens: maxTokens))
            return state.calls.count
        }
        return try await handler(call, messages, maxTokens)
    }
}

extension GenerationResult {
    static func done(_ text: String) -> GenerationResult { GenerationResult(text: text, stoppedByTokenLimit: false) }
    static func cutOff(_ text: String) -> GenerationResult { GenerationResult(text: text, stoppedByTokenLimit: true) }
}

/// Polls until `condition` holds, for at most five seconds.
func notesEventually(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<500 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}
