import Foundation
import llama

/// Test-only llama.cpp wrapper for the span-selection prototype: loads a GGUF, applies the model's chat
/// template, keeps the KV cache of the prompt prefix shared with the previous request, and decodes greedily
/// under a GBNF grammar (`llama_sampler_init_grammar`), so the answer can only be `none` or a window number.
/// Not product code: `LlamaRuntime` has no grammar parameter and is not touched.
final class SpanLlama: @unchecked Sendable {
    enum Failure: Error {
        case load, context, template, tokenize
        case decode(Int32)
        case grammar
    }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocabulary: OpaquePointer
    private var cached: [llama_token] = []

    init(path: String, contextLength: UInt32 = 4096) throws {
        llama_backend_init()
        llama_log_set({ _, _, _ in }, nil)
        var modelParameters = llama_model_default_params()
        modelParameters.n_gpu_layers = -1
        guard let model = llama_model_load_from_file(path, modelParameters) else { throw Failure.load }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = contextLength
        contextParameters.no_perf = true
        guard let context = llama_init_from_model(model, contextParameters) else {
            llama_model_free(model)
            throw Failure.context
        }
        guard let vocabulary = llama_model_get_vocab(model) else {
            llama_free(context)
            llama_model_free(model)
            throw Failure.load
        }
        self.model = model
        self.context = context
        self.vocabulary = vocabulary
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    struct Answer {
        let text: String
        let promptTokens: Int
        /// Prompt tokens that had to be decoded (the rest came from the cache).
        let decodedTokens: Int
        let seconds: Double
    }

    func resetCache() {
        llama_memory_clear(llama_get_memory(context), true)
        cached = []
    }

    func answer(
        messages: [(role: String, content: String)], grammar: String?, reuseCache: Bool, maxTokens: Int = 6
    ) throws -> Answer {
        let started = ContinuousClock.now
        let tokens = try tokenize(try prompt(messages))
        if !reuseCache { resetCache() }
        var common = 0
        while common < min(cached.count, tokens.count - 1), cached[common] == tokens[common] { common += 1 }
        let memory = llama_get_memory(context)
        // A recurrent or hybrid model (Qwen3.5) cannot drop the tail of its state: decode the whole prompt then.
        if common < cached.count, !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
            llama_memory_clear(memory, true)
            common = 0
        }
        if common == 0 { llama_memory_clear(memory, true) }
        var rest = Array(tokens[common...])
        var offset = 0
        while offset < rest.count {
            let count = min(512, rest.count - offset)
            let status = rest.withUnsafeMutableBufferPointer { buffer -> Int32 in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + offset, Int32(count)))
            }
            guard status == 0 else { throw Failure.decode(status) }
            offset += count
        }
        cached = tokens

        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { throw Failure.grammar }
        defer { llama_sampler_free(chain) }
        if let grammar {
            guard let constraint = llama_sampler_init_grammar(vocabulary, grammar, "root") else {
                throw Failure.grammar
            }
            llama_sampler_chain_add(chain, constraint)
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        var output: [UInt8] = []
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(chain, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            output.append(contentsOf: piece(token))
            let status = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            guard status == 0 else { throw Failure.decode(status) }
            // The generated token is part of the cache now; the next prompt is compared with `cached`.
            cached.append(token)
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        rest.removeAll()
        return Answer(
            text: String(decoding: output, as: UTF8.self), promptTokens: tokens.count,
            decodedTokens: tokens.count - common, seconds: seconds)
    }

    /// Gemma 4's turn format, written by hand because `llama_chat_apply_template` (the only template API in the
    /// C library, and the one `LlamaRuntime` uses) does not know its Jinja template. Read off the template in the
    /// GGUF: `<|turn>role\n...<turn|>\n`, the assistant role is `model`, the generation prompt `<|turn>model\n`.
    static var useGemma4Template: Bool { ProcessInfo.processInfo.environment["LINTEL_SPAN_TEMPLATE"] == "gemma4" }

    private func prompt(_ messages: [(role: String, content: String)]) throws -> String {
        if Self.useGemma4Template {
            var text = ""
            for message in messages {
                let role = message.role == "assistant" ? "model" : message.role
                text += "<|turn>\(role)\n\(message.content.trimmingCharacters(in: .whitespacesAndNewlines))<turn|>\n"
            }
            return text + "<|turn>model\n"
        }
        guard let template = llama_model_chat_template(model, nil) else { throw Failure.template }
        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { for string in strings { free(string) } }
        var chat: [llama_chat_message] = []
        var size = 0
        for message in messages {
            guard let role = strdup(message.role), let content = strdup(message.content) else { throw Failure.template }
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
        guard length > 0 else { throw Failure.template }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 16)
        var count = llama_tokenize(vocabulary, text, length, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocabulary, text, length, &tokens, Int32(tokens.count), true, true)
        }
        guard count > 0 else { throw Failure.tokenize }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        if count < 0 {
            buffer = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(max(0, Int(count))).map { UInt8(bitPattern: $0) }
    }
}
