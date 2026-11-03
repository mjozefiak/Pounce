import Foundation
import os

/// What came back for one chunk: the text to use and whether it is the cleaned version.
struct FormatResult: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case formatted
        /// The raw text was kept; the reason is for the HUD and the logs.
        case fellBack(FallbackReason)
    }

    var text: String
    var outcome: Outcome
}

enum FallbackReason: Equatable, Sendable {
    /// No server or model is chosen.
    case notConfigured
    /// The server did not answer in time, refused the connection or answered with an error.
    case unreachable
    case badResponse
    /// The built-in model is not installed or failed to load.
    case modelUnavailable
    /// The built-in model did not finish in time.
    case timedOut
    case rejected(FormatterGuard.Reason)
}

/// Turns the raw text of one chunk into clean text (spec: `TextFormatter`). Never throws for a bad server:
/// a chunk that cannot be formatted comes back raw. Only cancellation throws.
protocol TextFormatter: Sendable {
    func format(chunk: String, previousContext: String?) async throws -> FormatResult
    /// Called when a recording starts, so a formatter that has to load a model can do it while the user speaks.
    func prepare() async
}

extension TextFormatter {
    func prepare() async {}
}

/// Raw mode: the chunk as it is.
struct RawFormatter: TextFormatter {
    func format(chunk: String, previousContext: String?) async throws -> FormatResult {
        FormatResult(text: chunk, outcome: .formatted)
    }
}

/// Cleans a chunk with the user's own OpenAI-compatible server on this Mac (Ollama, LM Studio,
/// llama-server): `POST /v1/chat/completions`, `stream: false`, `temperature: 0`.
struct LocalLLMFormatter: TextFormatter {
    /// The server and model; read for every chunk, so a change in Settings applies at once.
    struct Target: Equatable, Sendable {
        var baseURL: URL
        var model: String
    }

    private let transport: any HTTPTransport
    private let target: @Sendable () -> Target?
    private let logger: Logger

    init(
        transport: any HTTPTransport, target: @escaping @Sendable () -> Target?,
        logger: Logger = Logger(subsystem: "app.pounce", category: "dictation")
    ) {
        self.transport = transport
        self.target = target
        self.logger = logger
    }

    /// 5 s plus 0.2 s a word (17 s for 60 words), spec and ADR 0004.
    static func timeout(forWords words: Int) -> TimeInterval { 5 + Double(words) * 0.1 * 2 }

    func format(chunk: String, previousContext: String?) async throws -> FormatResult {
        let raw = FormatResult.raw(chunk)
        guard let target = target() else { return raw.falling(.notConfigured) }
        let words = FormatterGuard.words(in: chunk)
        let request: URLRequest
        do {
            request = try Self.request(for: target, chunk: chunk, context: previousContext, words: words)
        } catch {
            return raw.falling(.badResponse)
        }

        let data: Data
        do {
            data = try await send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Never the text, only the kind of failure.
            logger.error("The formatting server failed: \(String(describing: type(of: error)), privacy: .public)")
            return raw.falling(.unreachable)
        }
        try Task.checkCancellation()

        guard let content = Self.content(of: data) else { return raw.falling(.badResponse) }
        switch FormatterGuard.check(input: chunk, output: content) {
        case .accepted(let text):
            return FormatResult(text: text, outcome: .formatted)
        case .rejected(let reason):
            logger.info("A formatted chunk was rejected: \(String(describing: reason), privacy: .public)")
            return raw.falling(.rejected(reason))
        }
    }

    /// One try, and one more after a connection error (spec: no other retries in a session).
    private func send(_ request: URLRequest) async throws -> Data {
        do {
            return try await attempt(request)
        } catch let error as URLError where Self.isConnectionError(error) {
            try Task.checkCancellation()
            return try await attempt(request)
        }
    }

    private func attempt(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else { throw HTTPFailure(status: response.statusCode) }
        return data
    }

    private struct HTTPFailure: Error { let status: Int }

    private static func isConnectionError(_ error: URLError) -> Bool {
        [.cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code)
    }

    static func request(for target: Target, chunk: String, context: String?, words: Int) throws -> URLRequest {
        struct Body: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }
            struct TemplateOptions: Encodable {
                let enableThinking = false
                enum CodingKeys: String, CodingKey { case enableThinking = "enable_thinking" }
            }
            let model: String
            let messages: [Message]
            let temperature = 0
            let stream = false
            let maxTokens: Int
            let templateOptions = TemplateOptions()
            enum CodingKeys: String, CodingKey {
                case model, messages, temperature, stream
                case maxTokens = "max_tokens"
                case templateOptions = "chat_template_kwargs"
            }
        }
        let body = Body(
            model: target.model,
            messages: CleanupPrompt.messages(transcript: chunk, context: context).map {
                .init(role: $0.role, content: $0.content)
            },
            maxTokens: words * 4 + 64)
        var request = URLRequest(url: target.baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = timeout(forWords: words)
        return request
    }

    static func content(of data: Data) -> String? {
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.choices.first?.message.content
    }
}

extension FormatResult {
    static func raw(_ text: String) -> FormatResult { FormatResult(text: text, outcome: .formatted) }

    fileprivate func falling(_ reason: FallbackReason) -> FormatResult {
        FormatResult(text: text, outcome: .fellBack(reason))
    }
}
