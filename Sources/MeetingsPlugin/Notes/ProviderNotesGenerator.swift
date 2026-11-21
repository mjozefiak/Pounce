import Foundation
import LintelProviders
import LintelSpeech

/// The whole-transcript track's generator over an external provider's CLI (spec `2026-11-10-external-ai-providers`,
/// "ProviderNotesGenerator"; owner decision 2026-11-20: choosing the provider in settings is the consent).
///
/// Every request goes through `ProviderRunner.run`, which asks the authorization given here directly before the
/// process starts. The authorization reads the settings again at that moment: it allows the start only while the
/// user still has this provider chosen, so a switch back to the built-in model, a removed value or one that no
/// longer parses stops the next process (a retry and the next part of a long meeting included). A change of the
/// model at the same provider is not asked about; this job keeps the model it started with, so notes are never
/// put together from two models.
///
/// What leaves the Mac in a request: the serialized `WholeNotesPrompt` (our static prompt in argv; the transcript
/// with speaker names and times on stdin). EXTENSION POINT (ADR 0013): the approved dictation vocabulary terms
/// would be added to the input in `generateResult`, below, once the port that lends them to Meetings exists in
/// `LintelKit`. Nothing of the user's is logged here, and no error carries text.
struct ProviderNotesGenerator: NotesGenerating {
    let profile: NotesGeneratorProfile
    let selection: NotesProviderSelection
    private let runner: ProviderRunner
    private let currentSelection: @Sendable () -> NotesProviderSelection?
    private let timeout: Duration
    private let onFailure: @Sendable (ProviderJobFailure.Reason) -> Void
    private let onExactModel: @Sendable (String) -> Void

    /// `currentSelection` is read at every authorization question, not once per job. `onFailure` gets the closed
    /// reason of a failed attempt (the Settings banner shows it); it never carries text.
    init(
        runner: ProviderRunner, selection: NotesProviderSelection, inputBudgetTokens: Int,
        currentSelection: @escaping @Sendable () -> NotesProviderSelection?, timeout: Duration = .seconds(600),
        onFailure: @escaping @Sendable (ProviderJobFailure.Reason) -> Void = { _ in },
        onExactModel: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.onExactModel = onExactModel
        self.onFailure = onFailure
        self.runner = runner
        self.selection = selection
        self.currentSelection = currentSelection
        self.timeout = timeout
        profile = NotesGeneratorProfile(
            strategy: .wholeTranscript, inputBudgetTokens: inputBudgetTokens,
            promptFormat: WholeNotesPrompt.version + "+" + ProviderPromptSerializer.format)
    }

    func open() async throws {}
    func release() async {}

    func generateResult(
        messages: [ChatMessage], maxTokens: Int, onPhase: (@Sendable (GenerationPhase) -> Void)?
    ) async throws -> GenerationResult {
        let serialized = ProviderPromptSerializer.serialize(messages)
        let request = ProviderRequest(
            provider: selection.provider, feature: .meetingsNotes, model: selection.model,
            messages: [
                ChatMessage(role: "system", content: serialized.system),
                ChatMessage(role: "user", content: serialized.input),
            ], timeout: timeout)
        let provider = selection.provider
        let model = selection.model
        let current = currentSelection
        let authorization: ProviderAuthorization = {
            guard let chosen = current() else { return .denied(.noConsent) }
            guard chosen.provider == provider else { return .denied(.otherProvider) }
            return chosen.model == model ? .allowed : .denied(.otherModel)
        }
        // The time limit of the pipeline counts from here (it counts only a request that is running).
        onPhase?(.running)
        do {
            return try await runner.run(request, authorization: authorization, onExactModel: onExactModel)
        } catch let error as ProviderError {
            if let reason = Self.reason(of: error) { onFailure(reason) }
            throw Self.map(error)
        }
    }

    /// The closed reason the Settings banner names; `nil` for what is no failure of the provider (a refusal, a
    /// cancellation).
    static func reason(of error: ProviderError) -> ProviderJobFailure.Reason? {
        switch error {
        case .notAuthorized, .cancelled: return nil
        case .notInstalled: return .notInstalled
        case .timedOut: return .timedOut
        case .failed(let failure):
            switch failure {
            case .notSignedIn: return .notSignedIn
            case .incompatibleVersion: return .incompatibleVersion
            case .modelNotAvailable: return .modelNotAvailable
            case .rateLimited: return .rateLimited
            case .network: return .network
            case .other: return .other
            }
        case .isolationNotVerified, .isolationProblem, .unsupportedProvider, .invalidModel, .invalidRequest,
            .outputTooLarge, .launchFailed:
            return .other
        }
    }

    /// A refusal ends the job at once; a cancelled process is a cancellation; what cannot work however often it is
    /// tried (no CLI, no isolation proof, a bad model id) ends the job without a retry; the rest is a failed attempt.
    static func map(_ error: ProviderError) -> any Error {
        switch error {
        case .notAuthorized: return NotesGenerationRefusal()
        case .cancelled: return CancellationError()
        case .notInstalled, .isolationNotVerified, .isolationProblem, .unsupportedProvider, .invalidModel,
            .invalidRequest:
            return NotesFailure.modelUnavailable
        case .timedOut, .outputTooLarge, .failed, .launchFailed: return error
        }
    }
}
