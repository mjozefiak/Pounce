import Foundation
import llama

enum LlamaError: Error, Equatable, Sendable {
    case modelNotFound
    case loadFailed
    case contextFailed
    case notLoaded
    /// The model's chat template is not one llama.cpp knows, or the messages could not be prepared.
    case unsupportedTemplate
    case tokenizeFailed
    case promptTooLong(tokens: Int, limit: Int)
    case decodeFailed(Int)
}

/// The built-in language model behind one narrow port (ADR 0005): load a file, produce a completion for a chat,
/// free the memory. The formatter and its tests only see this protocol.
protocol LLMRuntime: Sendable {
    var isLoaded: Bool { get async }
    func load(modelAt url: URL) async throws
    func unload() async
    /// Greedy completion of `messages`. Cancelling the calling task stops it between two tokens.
    func generate(messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> String
}

/// llama.cpp in this process. The actor runs on its own serial queue, so a decode never blocks the main thread
/// or the cooperative pool. Nothing here logs the prompt or the answer.
actor LlamaRuntime: LLMRuntime {
    /// The longest prompt plus answer: the cleanup prompt with its examples, a 60-word chunk and its answer.
    static let contextLength = 4096

    private let queue = DispatchSerialQueue(label: "app.pounce.dictation.llama", qos: .userInitiated)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var engine: Engine?

    var isLoaded: Bool { engine != nil }

    func load(modelAt url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LlamaError.modelNotFound }
        engine = nil
        Self.prepareBackend()
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(url.path, modelParameters) else { throw LlamaError.loadFailed }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(Self.contextLength)
        contextParameters.no_perf = true
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        guard let vocabulary = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw LlamaError.loadFailed
        }
        engine = Engine(model: model, context: context, vocabulary: vocabulary)
    }

    func unload() {
        engine = nil
    }

    func generate(messages: [CleanupPrompt.Message], maxTokens: Int) async throws -> String {
        guard let engine else { throw LlamaError.notLoaded }
        let tokens = try Self.tokens(of: try Self.prompt(for: messages, in: engine), in: engine)
        guard tokens.count + maxTokens <= Self.contextLength else {
            throw LlamaError.promptTooLong(tokens: tokens.count, limit: Self.contextLength - maxTokens)
        }
        llama_memory_clear(llama_get_memory(engine.context), true)
        try Self.decodePrompt(tokens, in: engine)
        return try Self.sample(maxTokens: maxTokens, in: engine)
    }

    // MARK: llama.cpp

    private static let backendReady: Void = {
        llama_backend_init()
        // llama.cpp prints loading details to stderr; the app does not need them.
        llama_log_set({ _, _, _ in }, nil)
    }()

    private static func prepareBackend() {
        _ = backendReady
    }

    /// The messages in the model's own chat format, ready for the next assistant turn.
    private static func prompt(for messages: [CleanupPrompt.Message], in engine: Engine) throws -> String {
        guard let template = llama_model_chat_template(engine.model, nil) else { throw LlamaError.unsupportedTemplate }
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer {
            for string in strings { free(string) }
        }
        var chat: [llama_chat_message] = []
        var size = 0
        for message in messages {
            guard let role = strdup(message.role), let content = strdup(message.content) else {
                throw LlamaError.unsupportedTemplate
            }
            strings.append(role)
            strings.append(content)
            chat.append(llama_chat_message(role: role, content: content))
            size += message.role.utf8.count + message.content.utf8.count
        }
        var buffer = [CChar](repeating: 0, count: max(4096, size * 2))
        var length = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        if length > buffer.count {
            buffer = [CChar](repeating: 0, count: Int(length))
            length = llama_chat_apply_template(template, chat, chat.count, true, &buffer, Int32(buffer.count))
        }
        guard length > 0 else { throw LlamaError.unsupportedTemplate }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tokens(of text: String, in engine: Engine) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 16)
        var count = llama_tokenize(engine.vocabulary, text, length, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(engine.vocabulary, text, length, &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private static func decodePrompt(_ tokens: [llama_token], in engine: Engine) throws {
        let step = 512
        var tokens = tokens
        var offset = 0
        while offset < tokens.count {
            try Task.checkCancellation()
            let count = min(step, tokens.count - offset)
            let status = tokens.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let base = buffer.baseAddress else { return -1 }
                return llama_decode(engine.context, llama_batch_get_one(base + offset, Int32(count)))
            }
            guard status == 0 else { throw LlamaError.decodeFailed(Int(status)) }
            offset += count
        }
    }

    private static func sample(maxTokens: Int, in engine: Engine) throws -> String {
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LlamaError.contextFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var output: [UInt8] = []
        for _ in 0..<maxTokens {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, engine.context, -1)
            if llama_vocab_is_eog(engine.vocabulary, token) { break }
            output.append(contentsOf: piece(of: token, in: engine))
            let status = withUnsafeMutablePointer(to: &token) {
                llama_decode(engine.context, llama_batch_get_one($0, 1))
            }
            guard status == 0 else { throw LlamaError.decodeFailed(Int(status)) }
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func piece(of token: llama_token, in engine: Engine) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(engine.vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(engine.vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(max(0, Int(count))).map { UInt8(bitPattern: $0) }
    }

    /// The loaded model and its context. Freed when the actor lets go of it, in the order llama.cpp needs.
    private final class Engine: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocabulary: OpaquePointer

        init(model: OpaquePointer, context: OpaquePointer, vocabulary: OpaquePointer) {
            self.model = model
            self.context = context
            self.vocabulary = vocabulary
        }

        deinit {
            llama_free(context)
            llama_model_free(model)
        }
    }
}
