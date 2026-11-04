import Foundation
import Synchronization
import Testing

@testable import DictationPlugin
@testable import PounceSpeech

private func words(_ count: Int, sentenceEvery: Int? = nil) -> String {
    (1...count).map { index in
        let end = sentenceEvery.map { index % $0 == 0 } ?? false
        return "w\(index)" + (end ? "." : "")
    }.joined(separator: " ")
}

@Suite struct SegmenterTests {
    @Test func aShortRecordingIsOneChunkAtTheEnd() {
        var segmenter = Segmenter()
        #expect(segmenter.add(words(10), pauseBefore: 0).isEmpty)
        #expect(segmenter.flush() == [.init(text: words(10), endsParagraph: true)])
    }

    @Test func aLongPauseAfterEnoughWordsClosesTheParagraph() {
        var segmenter = Segmenter()
        #expect(segmenter.add(words(45), pauseBefore: 0).isEmpty)
        let done = segmenter.add("next part", pauseBefore: 1.6)
        #expect(done == [.init(text: words(45), endsParagraph: true)])
        #expect(segmenter.flush() == [.init(text: "next part", endsParagraph: true)])
    }

    @Test func aLongPauseBeforeEnoughWordsDoesNotCut() {
        var segmenter = Segmenter()
        _ = segmenter.add(words(20), pauseBefore: 0)
        #expect(segmenter.add("more", pauseBefore: 5).isEmpty)
    }

    @Test func aShortPauseDoesNotCutEvenWithManyWords() {
        var segmenter = Segmenter()
        _ = segmenter.add(words(50), pauseBefore: 0)
        #expect(segmenter.add("more", pauseBefore: 1.4).isEmpty)
    }

    @Test func overTheLimitIsCutAtTheLastSentenceEnd() {
        var segmenter = Segmenter()
        let done = segmenter.add(words(70, sentenceEvery: 25), pauseBefore: 0)
        // Sentences end at 25 and 50; 70 words exceed 60, so the cut is after word 50.
        #expect(done.count == 1)
        #expect(FormatterGuard.words(in: done[0].text) == 50)
        #expect(done[0].endsParagraph == false)
        let rest: [String] = (51...70).map { index -> String in
            index % 25 == 0 ? "w\(index)." : "w\(index)"
        }
        #expect(segmenter.flush() == [Segmenter.Chunk(text: rest.joined(separator: " "), endsParagraph: true)])
    }

    @Test func withoutASentenceEndTheCutIsAtTheLimit() {
        var segmenter = Segmenter()
        let done = segmenter.add(words(130), pauseBefore: 0)
        #expect(done.map { FormatterGuard.words(in: $0.text) } == [60, 60])
        #expect(segmenter.flush().map { FormatterGuard.words(in: $0.text) } == [10])
    }

    @Test func theTailIsCutByTheSameLimit() {
        var segmenter = Segmenter()
        _ = segmenter.add(words(59), pauseBefore: 0)
        // 59 words stay; one more segment of 80 words pushes the buffer over the limit at the next add.
        let done = segmenter.add(words(80), pauseBefore: 0)
        #expect(done.allSatisfy { FormatterGuard.words(in: $0.text) <= 60 })
        let tail = segmenter.flush()
        #expect(tail.allSatisfy { FormatterGuard.words(in: $0.text) <= 60 })
        let total = (done + tail).map { FormatterGuard.words(in: $0.text) }.reduce(0, +)
        #expect(total == 139)
    }

    @Test func nothingIsLost() {
        var segmenter = Segmenter()
        var chunks: [Segmenter.Chunk] = []
        for index in 0..<30 {
            chunks += segmenter.add(words(17), pauseBefore: index % 4 == 0 ? 2 : 0.2)
        }
        chunks += segmenter.flush()
        #expect(chunks.map { FormatterGuard.words(in: $0.text) }.reduce(0, +) == 30 * 17)
        #expect(chunks.allSatisfy { FormatterGuard.words(in: $0.text) <= 60 })
    }
}

/// Answers after a delay that depends on the chunk, to make answers arrive out of order.
private final class ChunkLog: Sendable {
    private let inner = Mutex<[(chunk: String, context: String?)]>([])
    func add(_ chunk: String, _ context: String?) { inner.withLock { $0.append((chunk, context)) } }
    var all: [(chunk: String, context: String?)] { inner.withLock { $0 } }
}

private let second = AudioFormat.sampleRate

@Suite struct FormattingSessionTests {
    /// Six speech segments of one second, 2 s apart, so the pauses are long.
    private func run(
        seconds: Double = 20, ranges: [Range<Int>]? = nil, formatter: any TextFormatter,
        engine: FakeEngine = FakeEngine(), cancelAfterFormatStarts: Bool = false
    ) async throws -> DictationSession.Output {
        let ranges = ranges ?? (0..<6).map { ($0 * 3 * second + second)..<($0 * 3 * second + 2 * second) }
        let session = DictationSession(
            audio: ScriptedAudioInput(seconds: seconds), vad: RangeVAD(ranges), engine: engine, formatter: formatter,
            modelFolder: URL(filePath: "/tmp/none"))
        try await session.start()
        try await Task.sleep(for: .milliseconds(200))
        return try await session.finish()
    }

    @Test func withoutAFormatterTheTextIsTheJoinedSegments() async throws {
        let output = try await run(formatter: RawFormatter())
        #expect(output.rawText.hasPrefix("segment 1 segment 4"))
        #expect(output.formatting.chunks >= 1)
    }

    @Test func chunksAreFormattedInOrderWhateverOrderTheAnswersComeIn() async throws {
        // Every segment is ~one word group; force a chunk per segment with a tiny soft limit via many words.
        let engine = FakeEngine()
        let log = ChunkLog()
        let formatter = StubFormatter { chunk, context in
            log.add(chunk, context)
            // Later chunks answer faster than earlier ones.
            let delay = chunk.contains("segment 1") ? 120 : (chunk.contains("segment 7") ? 60 : 5)
            try await Task.sleep(for: .milliseconds(delay))
            return FormatResult(text: "F(\(chunk))", outcome: .formatted)
        }
        let output = try await run(formatter: formatter, engine: engine)
        #expect(output.text.hasPrefix("F(segment 1"))
        #expect(output.formatting.fellBack == 0)
        // Every raw word appears exactly once and in the order it was said.
        let rebuilt = output.text.replacingOccurrences(of: "F(", with: "").replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "\n\n", with: " ")
        #expect(rebuilt == output.rawText)
    }

    @Test func eachChunkGetsTheEndOfThePreviousOneAsContext() async throws {
        let log = ChunkLog()
        let formatter = StubFormatter { chunk, context in
            log.add(chunk, context)
            return FormatResult(text: chunk, outcome: .formatted)
        }
        // Long segments so that more than one chunk is produced.
        let engine = FakeEngine()
        let session = DictationSession(
            audio: ScriptedAudioInput(seconds: 12),
            vad: RangeVAD([second..<(11 * second)]), engine: engine, formatter: formatter,
            modelFolder: URL(filePath: "/tmp/none"))
        try await session.start()
        _ = try await session.finish()
        let calls = log.all
        #expect(calls.first?.context == nil)
        for index in calls.indices.dropFirst() {
            #expect(calls[index].context == String(calls[index - 1].chunk.suffix(300)))
        }
    }

    @Test func aChunkThatFallsBackIsCountedAndKeptRaw() async throws {
        let formatter = StubFormatter { chunk, _ in
            FormatResult(text: chunk, outcome: .fellBack(.rejected(.tooShort)))
        }
        let output = try await run(formatter: formatter)
        #expect(output.formatting.isPartial)
        #expect(output.formatting.firstReason == .rejected(.tooShort))
        #expect(output.text.replacingOccurrences(of: "\n\n", with: " ") == output.rawText)
    }

    @Test func aPauseBetweenParagraphsBecomesABlankLine() async throws {
        // 45 words in the first segment, then a 2 s pause, then a short one.
        let engine = FakeEngine()
        let session = DictationSession(
            audio: ScriptedAudioInput(seconds: 8),
            vad: RangeVAD([second..<(2 * second), (5 * second)..<(6 * second)]),
            engine: LongTextEngine(first: 45), formatter: RawFormatter(), modelFolder: URL(filePath: "/tmp/none"))
        _ = engine
        try await session.start()
        let output = try await session.finish()
        #expect(output.text.contains("\n\n"))
        #expect(!output.rawText.contains("\n"))
    }

    @Test func cancellingWhileFormattingStopsTheFormatter() async throws {
        let started = Mutex(0)
        let finished = Mutex(0)
        let formatter = StubFormatter { chunk, _ in
            started.withLock { $0 += 1 }
            try await Task.sleep(for: .seconds(30))
            finished.withLock { $0 += 1 }
            return .raw(chunk)
        }
        let session = DictationSession(
            audio: ScriptedAudioInput(seconds: 12), vad: RangeVAD([second..<(11 * second)]), engine: FakeEngine(),
            formatter: formatter, modelFolder: URL(filePath: "/tmp/none"))
        try await session.start()
        let finishing = Task { try await session.finish() }
        for _ in 0..<200 where started.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        await session.cancel()
        await #expect(throws: DictationSession.Failure.cancelled) { try await finishing.value }
        #expect(finished.withLock { $0 } == 0)
    }
}

/// An engine whose first segment has `first` words and every other one a few.
private final class LongTextEngine: SpeechEngine, @unchecked Sendable {
    private let first: Int
    private let calls = Mutex(0)
    init(first: Int) { self.first = first }
    var isLoaded: Bool { true }
    func load(modelFolder: URL) async throws {}
    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment {
        let index = calls.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        return TranscriptSegment(text: index == 0 ? words(first) : "short tail")
    }
    func unload() async {}
}
