import Foundation
import PounceSpeech
import os

/// Cleans a chunk with the model that runs inside Pounce (ADR 0005): the same prompt, guard and fallbacks as
/// `LocalLLMFormatter`, with `LlamaRuntime` instead of a server. Never throws except on cancellation: a chunk
/// the model cannot clean in time comes back raw.
struct BuiltInFormatter: TextFormatter {
    /// Allowance on top of `LocalLLMFormatter.timeout` for the model to load when it is not in memory.
    static let loadAllowance: TimeInterval = 20

    private let runtime: KeepWarmRuntime
    private let timeout: @Sendable (Int) -> Duration
    private let logger: Logger

    /// - Parameter timeout: how long a chunk of this many words may take; tests shorten it.
    init(
        runtime: KeepWarmRuntime, timeout: @escaping @Sendable (Int) -> Duration = BuiltInFormatter.timeout(forWords:),
        logger: Logger = Logger(subsystem: "app.pounce", category: "dictation")
    ) {
        self.runtime = runtime
        self.timeout = timeout
        self.logger = logger
    }

    static func timeout(forWords words: Int) -> Duration {
        .seconds(LocalLLMFormatter.timeout(forWords: words) + loadAllowance)
    }

    /// Loads the model while the user is still speaking.
    func prepare() async {
        do {
            try await runtime.warmUp()
        } catch is CancellationError {
        } catch {
            logger.error("The built-in model failed to load: \(String(describing: error), privacy: .public)")
        }
    }

    func format(chunk: String, previousContext: String?) async throws -> FormatResult {
        let raw = FormatResult.raw(chunk)
        let words = FormatterGuard.words(in: chunk)
        let messages = CleanupPrompt.messages(transcript: chunk, context: previousContext)
        let runtime = runtime
        let outcome: Result<String, any Error>?
        do {
            outcome = try await FirstResult.within(timeout(words)) {
                do {
                    return .success(try await runtime.generate(messages: messages, maxTokens: words * 4 + 64))
                } catch {
                    return .failure(error)
                }
            }
        } catch {
            throw CancellationError()
        }
        try Task.checkCancellation()

        guard let outcome else {
            logger.error("The built-in model did not answer in time")
            return raw.falling(.timedOut)
        }
        switch outcome {
        case .failure(let error):
            if error is CancellationError { throw CancellationError() }
            logger.error("The built-in model failed: \(String(describing: type(of: error)), privacy: .public)")
            return raw.falling(Self.reason(for: error))
        case .success(let content):
            switch FormatterGuard.check(input: chunk, output: content) {
            case .accepted(let text):
                return FormatResult(text: text, outcome: .formatted)
            case .rejected(let reason):
                logger.info("A formatted chunk was rejected: \(String(describing: reason), privacy: .public)")
                return raw.falling(.rejected(reason))
            }
        }
    }

    private static func reason(for error: any Error) -> FallbackReason {
        if error as? ModelLeaseError == .busy { return .modelUnavailable }
        switch error as? LlamaError {
        case .modelNotFound, .loadFailed, .contextFailed, .notLoaded: return .modelUnavailable
        default: return .badResponse
        }
    }
}

extension FormatResult {
    fileprivate func falling(_ reason: FallbackReason) -> FormatResult {
        FormatResult(text: text, outcome: .fellBack(reason))
    }
}

/// Runs an operation and gives up on it after a time limit without waiting for it to finish: a model load
/// cannot be interrupted, and the caller must not wait for it.
enum FirstResult {
    /// The operation's value, or `nil` when the time ran out first. Cancelling the caller cancels the
    /// operation and throws `CancellationError`.
    static func within<T: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async -> T
    ) async throws -> T? {
        let gate = Gate<T?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T?, any Error>) in
                gate.install(continuation)
                let work = Task { gate.finish(.success(await operation())) }
                let timer = Task {
                    do { try await Task.sleep(for: limit) } catch { return }
                    gate.finish(.success(nil))
                }
                gate.onFinish {
                    work.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the continuation exactly once, with whichever result arrives first.
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var cleanup: (@Sendable () -> Void)?
        private var early: Result<T, any Error>?
        private var done = false

        func install(_ continuation: CheckedContinuation<T, any Error>) {
            lock.lock()
            defer { lock.unlock() }
            if let early {
                done = true
                continuation.resume(with: early)
            } else {
                self.continuation = continuation
            }
        }

        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            lock.lock()
            let run = done
            if !run { self.cleanup = cleanup }
            lock.unlock()
            if run { cleanup() }
        }

        func finish(_ result: Result<T, any Error>) {
            lock.lock()
            if done {
                lock.unlock()
                return
            }
            guard let continuation else {
                // Cancelled before the continuation exists: remember it for `install`.
                if early == nil { early = result }
                lock.unlock()
                return
            }
            done = true
            self.continuation = nil
            let cleanup = self.cleanup
            lock.unlock()
            continuation.resume(with: result)
            cleanup?()
        }
    }
}
