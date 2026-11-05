import Foundation
import WhisperKit

/// Whisper large-v3-turbo through WhisperKit, with the language pinned to what the user chose (ADR 0003: the
/// answer to Parakeet drifting into English). It loads only from the folder `ModelManager` gives it, with
/// `download: false`, and the tokenizer files sit in that folder, so WhisperKit has nothing to fetch.
public actor WhisperKitEngine: SpeechEngine {
    public enum EngineError: Error {
        case notLoaded
    }

    private var kit: WhisperKit?
    private let language: @Sendable () -> String

    /// - Parameter language: `pl` or `en`, read for every segment so a change in Settings applies at once.
    public init(language: @escaping @Sendable () -> String) {
        self.language = language
    }

    public var isLoaded: Bool { kit != nil }

    public func load(modelFolder: URL) async throws {
        let config = WhisperKitConfig(
            modelFolder: modelFolder.path,
            tokenizerFolder: modelFolder,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false)
        kit = try await WhisperKit(config)
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        guard let kit else { throw EngineError.notLoaded }
        // The language is always pinned (no detection), and a VAD segment is one window, not 30 s chunks.
        let options = DecodingOptions(
            task: .transcribe,
            language: language(),
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            wordTimestamps: false)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")
        return TranscriptSegment(text: RepetitionFilter.clean(text))
    }

    public func unload() async {
        await kit?.unloadModels()
        kit = nil
    }
}

/// Whisper sometimes loops on one phrase ("thank you, thank you, thank you, ..."). A phrase repeated that
/// many times in a row is cut down to its first occurrence; ordinary repetition in speech is left alone.
public enum RepetitionFilter {
    /// A single word has to repeat this many times in a row to count as a loop ("no no no" is speech).
    static let wordRepeats = 5
    /// A phrase of two to eight words has to repeat this many times.
    static let phraseRepeats = 3
    static let longestPhrase = 8

    public static func clean(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var changed = true
        while changed {
            changed = false
            for length in 1...longestPhrase {
                let threshold = length == 1 ? wordRepeats : phraseRepeats
                var start = 0
                while start + length * threshold <= words.count {
                    let repeats = repeatCount(of: length, at: start, in: words)
                    if repeats >= threshold {
                        words.removeSubrange((start + length)..<(start + length * repeats))
                        changed = true
                    }
                    start += 1
                }
            }
        }
        return words.joined(separator: " ")
    }

    /// How many times the `length` words at `start` occur in a row.
    private static func repeatCount(of length: Int, at start: Int, in words: [String]) -> Int {
        let phrase = words[start..<(start + length)].map(normalize)
        var count = 1
        var next = start + length
        while next + length <= words.count, words[next..<(next + length)].map(normalize) == phrase {
            count += 1
            next += length
        }
        return count
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}

/// Presents the two engines as one: the model chosen in Settings is loaded and used, and the other one is
/// unloaded the moment the choice changes, so only one model sits in memory.
public actor SwitchingEngine: SpeechEngine {
    private let engines: [String: any SpeechEngine]
    private let selected: @Sendable () -> String
    private var active: String?

    public init(engines: [String: any SpeechEngine], selected: @escaping @Sendable () -> String) {
        self.engines = engines
        self.selected = selected
    }

    public enum SwitchingError: Error {
        case unknownEngine(String)
    }

    private func current() throws -> (id: String, engine: any SpeechEngine) {
        let id = selected()
        guard let engine = engines[id] else { throw SwitchingError.unknownEngine(id) }
        return (id, engine)
    }

    public var isLoaded: Bool {
        get async {
            guard let (id, engine) = try? current(), active == id else { return false }
            return await engine.isLoaded
        }
    }

    public func load(modelFolder: URL) async throws {
        let (id, engine) = try current()
        if let previous = active, previous != id, let old = engines[previous] {
            await old.unload()
        }
        active = id
        try await engine.load(modelFolder: modelFolder)
    }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        try await current().engine.transcribe(samples)
    }

    public func unload() async {
        for engine in engines.values {
            await engine.unload()
        }
        active = nil
    }
}
