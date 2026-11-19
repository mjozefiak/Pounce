import os

/// The only logger of this target. It takes codes from closed enums, counts and times, never argv, stdin, stdout,
/// stderr, an answer, an e-mail address or a path (`ProviderLogScanTests` scans the sources).
enum ProviderLogCode: String {
    case refusedIsolationNotVerified
    case refusedIsolationProblem
    case refusedNotAuthorized
    case refusedNotInstalled
    case contentProcessStarted
    case probeProcessStarted
    case processFinished
    case processTimedOut
    case processCancelled
    case outputTooLarge
    case launchFailed
}

struct ProviderLog: Sendable {
    private static let logger = Logger(subsystem: "com.lintelapp", category: "providers")

    static func record(_ code: ProviderLogCode, provider: ProviderID, millis: Int = 0) {
        logger.info(
            "providers \(code.rawValue, privacy: .public) \(provider.rawValue, privacy: .public) \(millis, privacy: .public) ms"
        )
    }
}
