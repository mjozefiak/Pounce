import FluidAudio
import Foundation
import Testing

@testable import LintelSpeech

/// Step 1.5, local only (off by default, like the benchmarks): the real Parakeet Ultra model and Silero VAD
/// from an installed model folder, on speech made with the system voice. It proves the folder `ModelManager`
/// fills is enough for FluidAudio, that nothing is downloaded (run it with the network off to be sure), and
/// that the Silero detector finds the speech in it.
///
/// `LINTEL_DICTATION_MODEL_FOLDER=~/Library/Application\ Support/Lintel/Plugins/dictation/Models/parakeet-ultra swift test --filter RealModelTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_DICTATION_MODEL_FOLDER"] != nil))
struct RealModelTests {
    private var folder: URL {
        URL(
            filePath: ProcessInfo.processInfo.environment["LINTEL_DICTATION_MODEL_FOLDER"] ?? "",
            directoryHint: .isDirectory)
    }

    /// Speech from the system voice, as 16 kHz mono samples.
    private func spokenSamples(_ text: String) throws -> [Float] {
        let file = FileManager.default.temporaryDirectory.appending(path: "lintel-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", file.path, text]
        try say.run()
        say.waitUntilExit()
        return try AudioConverter().resampleAudioFile(file)
    }

    @Test func parakeetTranscribesSpeechFromTheInstalledFolder() async throws {
        let engine = ParakeetEngine()
        try await engine.load(modelFolder: folder)
        let samples = try spokenSamples("Please write a short summary of the meeting notes.")
        let segment = try await engine.transcribe(samples)
        print("TRANSCRIPT:", segment.text)
        #expect(segment.text.lowercased().contains("summary"))
        await engine.unload()
        #expect(await !engine.isLoaded)
    }

    @Test func sileroFindsTheSpeechInTheInstalledFolder() async throws {
        let speech = try spokenSamples("Remember to review the pull request before lunch.")
        let silence = [Float](repeating: 0, count: 2 * AudioFormat.sampleRate)
        let vad = try SileroVAD(
            modelFolder: folder.appending(
                path: ModelCatalog.sileroVADPath, directoryHint: .isDirectory))
        let events = try await vad.process(silence + speech + silence)
        #expect(events.contains { $0.kind == .speechStart })
        #expect(events.contains { $0.kind == .speechEnd })
    }
}

/// Step 1.10, local only: Whisper large-v3-turbo from an installed folder, with the language pinned. Run with
/// the network off to confirm WhisperKit fetches nothing (the tokenizer is in the folder).
///
/// `LINTEL_DICTATION_WHISPER_FOLDER=.../Models/whisper-large-v3-turbo swift test --filter RealWhisperTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_DICTATION_WHISPER_FOLDER"] != nil))
struct RealWhisperTests {
    @Test func whisperTranscribesEnglishSpeechWithThePinnedLanguage() async throws {
        let folder = URL(
            filePath: ProcessInfo.processInfo.environment["LINTEL_DICTATION_WHISPER_FOLDER"] ?? "",
            directoryHint: .isDirectory)
        let engine = WhisperKitEngine(language: { "en" })
        try await engine.load(modelFolder: folder)
        let file = FileManager.default.temporaryDirectory.appending(path: "lintel-say-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: file) }
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", file.path, "Please write a short summary of the meeting notes."]
        try say.run()
        say.waitUntilExit()
        let samples = try AudioConverter().resampleAudioFile(file)
        let segment = try await engine.transcribe(samples)
        print("WHISPER:", segment.text)
        #expect(segment.text.lowercased().contains("summary"))
        await engine.unload()
    }
}
