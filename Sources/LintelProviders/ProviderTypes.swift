import Foundation
import LintelSpeech

/// Which provider a request goes to. Open set like `ModelKind`; v1 knows only the Claude Code CLI.
public struct ProviderID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let claudeCode = ProviderID(rawValue: "claude-code")
}

/// The feature that wants to send something. Consent is per feature id, so a future consumer needs its own consent.
public struct ProviderFeatureID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let meetingsNotes = ProviderFeatureID(rawValue: "meetings.notes")
}

/// Why the consumer refused. A closed set: the reason is logged, so it never carries text.
public enum ProviderDenial: String, Sendable, Equatable {
    case noConsent
    case outdatedConsent
    case otherProvider
    case otherModel
    case withdrawn
    case featureOff
}

public enum ProviderDecision: Sendable, Equatable {
    case allowed
    case denied(ProviderDenial)
}

/// Supplied by the consumer with every request and asked by `ProviderRunner` directly before every process start,
/// after the request left the queue. The runner has no way to start a content process without asking.
public typealias ProviderAuthorization = @Sendable () async -> ProviderDecision

/// The closed set a failure of the provider is sorted into. Stdout, stderr and API error text are classified and then
/// dropped: they are never logged, stored or put in an error.
public enum ProviderFailure: String, Sendable, Equatable {
    case incompatibleVersion
    case rateLimited
    case notSignedIn
    case network
    case other
}

public enum ProviderStatus: String, Sendable, Equatable {
    case notInstalled
    case notSignedIn
    case incompatibleVersion
    case ready
}

/// Errors of this target. No case carries user text, provider output or a path.
public enum ProviderError: Error, Sendable, Equatable {
    case notAuthorized(ProviderDenial)
    /// The descriptor has not passed the isolation canary (`isolationVerified == false`).
    case isolationNotVerified
    /// The argv misses an isolation requirement or has a forbidden flag. The names are constants of this target.
    case isolationProblem([String])
    case unsupportedProvider
    case invalidModel
    case invalidRequest
    case notInstalled
    case timedOut
    case cancelled
    case outputTooLarge
    case failed(ProviderFailure)
    /// The working directory or a pipe could not be made, or the process did not start.
    case launchFailed
}

/// One request with content. `messages` with the role `system` are the static Lintel prompt (it goes to argv, so it is
/// our text only); every other message is the user's content and goes to stdin only.
public struct ProviderRequest: Sendable {
    public let provider: ProviderID
    public let feature: ProviderFeatureID
    public let model: String
    public let messages: [ChatMessage]
    public let timeout: Duration

    public init(
        provider: ProviderID = .claudeCode,
        feature: ProviderFeatureID,
        model: String,
        messages: [ChatMessage],
        timeout: Duration = .seconds(600)
    ) {
        self.provider = provider
        self.feature = feature
        self.model = model
        self.messages = messages
        self.timeout = timeout
    }
}

/// What a content-free "Try it" run reports. Never the answer text.
public enum TryOutResult: Sendable, Equatable {
    case worked
    case failed(ProviderFailure)
    case unavailable
}
