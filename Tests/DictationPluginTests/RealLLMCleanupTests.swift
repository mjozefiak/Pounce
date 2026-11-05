import Foundation
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

@Suite struct RealLLMCleanupTests {
    /// Loads the GGUF in `LINTEL_LLAMA_MODEL` and cleans a Polish dictation with the real prompt. Off by default,
    /// like the other real-model tests (ADR 0005).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_LLAMA_MODEL"] != nil))
    func realModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LINTEL_LLAMA_MODEL"])
        let runtime = LlamaRuntime()
        let loadStarted = ContinuousClock.now
        try await runtime.load(modelAt: URL(fileURLWithPath: path))
        print("[llama] load \(ContinuousClock.now - loadStarted)")
        #expect(await runtime.isLoaded)

        let transcript = "yyy no więc jutro mamy spotkanie o dziesiątej nie to znaczy o jedenastej w biurze"
        let messages = CleanupPrompt.messages(transcript: transcript, context: nil)
        for run in ["first", "second"] {
            let started = ContinuousClock.now
            let text = try await runtime.generate(messages: messages, maxTokens: 96)
            print("[llama] \(run) request \(ContinuousClock.now - started): \(text)")
            #expect(!text.isEmpty)
            #expect(text.localizedCaseInsensitiveContains("jedenastej"))
            #expect(FormatterGuard.check(input: transcript, output: text) != .rejected(.empty))
        }

        // Cancelling stops the decode and leaves the runtime usable.
        let task = Task { try await runtime.generate(messages: messages, maxTokens: 512) }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await runtime.generate(messages: messages, maxTokens: 96).isEmpty == false)

        await runtime.unload()
        #expect(await runtime.isLoaded == false)
    }
}
