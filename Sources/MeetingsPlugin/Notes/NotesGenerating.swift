import Foundation
import LintelSpeech

/// How a generator writes the notes (spec `2026-11-10-external-ai-providers`, "Tor jednej generacji").
enum NotesStrategy: String, Sendable, Equatable {
    /// The built-in track: the model points at quotes in chunks, the code composes the notes.
    case quotedChunks
    /// One generation over the whole transcript; the model writes the notes, the code checks the facts.
    case wholeTranscript
}

/// What the track needs to know about a generator.
struct NotesGeneratorProfile: Equatable, Sendable {
    var strategy: NotesStrategy
    /// The estimated tokens of transcript one request takes (`NotesText.estimateTokens`).
    var inputBudgetTokens: Int
    /// The prompt format written to `notes_prompt_version`.
    var promptFormat: String
}

/// The port the notes tracks write through. A generator does not chunk: the track decides how the input is cut.
protocol NotesGenerating: Sendable {
    var profile: NotesGeneratorProfile { get }
    func open() async throws
    func generateResult(
        messages: [ChatMessage], maxTokens: Int, onPhase: (@Sendable (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult
    func release() async
}

/// The built-in model's generator is the lease of `NotesPipeline`, unchanged: the quoted-chunks track.
extension NotesLease: NotesGenerating {
    var profile: NotesGeneratorProfile {
        NotesGeneratorProfile(
            strategy: .quotedChunks, inputBudgetTokens: NotesModel.contextLength,
            promptFormat: String(NotesPrompt.version))
    }
}
