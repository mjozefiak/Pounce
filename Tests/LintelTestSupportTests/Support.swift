import Synchronization
import Testing

/// Runs `body`, swallows the issues it records and returns them, so a test can assert on what a guard reported.
func recordedIssues(isolation: isolated (any Actor)? = #isolation, _ body: () async -> Void) async -> [Issue] {
    let seen = Mutex<[Issue]>([])
    await withKnownIssue(isIntermittent: true) {
        await body()
    } matching: { issue in
        seen.withLock { $0.append(issue) }
        return true
    }
    return seen.withLock { $0 }
}

/// How a sleep ended in a round of the cancellation tests.
enum SleepEnd: Sendable { case woken, cancelled }

func sleepEnd(_ body: @Sendable () async throws -> Void) async -> SleepEnd {
    do {
        try await body()
        return .woken
    } catch is CancellationError {
        return .cancelled
    } catch {
        Issue.record("unexpected error \(error)")
        return .cancelled
    }
}
