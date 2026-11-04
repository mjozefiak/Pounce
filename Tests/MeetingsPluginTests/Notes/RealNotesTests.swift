import Darwin
import Foundation
import LintelSpeech
import Testing

@testable import MeetingsPlugin

/// Runs the notes on a REAL model. Off by default: it needs a GGUF file from `LLMModelCatalog` and takes minutes.
///
///     LINTEL_NOTES_LLM_MODEL=/path/to/Qwen3-4B-Instruct-2507-Q4_K_M.gguf \
///       swift test -c release --filter RealNotesTests
///
/// Optional: `LINTEL_NOTES_TRANSCRIPT=/path/to/transcript.txt` (one `[mm:ss] Speaker: text` line per utterance, for
/// example a real meeting) adds that transcript; `LINTEL_NOTES_LONG_REPEAT=<n>` repeats the bundled long
/// meeting n times (about 440 words each; 20 is the word count of one hour of speech) for the timing in `docs/perf.md`.
///
/// It asserts only what must hold for any model: no image, link or HTML in the notes, every point stands on a
/// quote that is in the recording, no task owner nobody named, and nothing the corpus lists as bait. It prints
/// the timings and the memory (`NOTES-BENCH …` lines); nothing is stored, and no transcript text is printed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_NOTES_LLM_MODEL"] != nil), .serialized)
struct RealNotesTests {
    private static var modelURL: URL? {
        ProcessInfo.processInfo.environment["LINTEL_NOTES_LLM_MODEL"].map { URL(filePath: $0) }
    }

    /// `phys_footprint` of this process, the number Activity Monitor calls Memory.
    static func footprintBytes() -> UInt64 {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    private static func megabytes(_ bytes: UInt64) -> Int { Int(bytes / 1_048_576) }

    private func pipeline(url: URL) -> NotesPipeline {
        var configuration = NotesPipeline.Configuration()
        configuration.chunkTokens = MeetingsSettings.defaultNotesChunkTokens
        configuration.reduceInputTokens = MeetingsSettings.defaultNotesReduceInputTokens
        let model = NotesModel(
            lease: LLMLease(), runtime: LlamaRuntime(contextLength: NotesModel.contextLength), modelURL: url,
            keepWarm: { .seconds(1) })
        return NotesPipeline(model: model, configuration: configuration)
    }

    private func report(
        _ name: String, transcript: [NotesUtterance], result: NotesResult, seconds: Double, before: UInt64
    ) {
        let words = transcript.reduce(0) { $0 + $1.text.split(separator: " ").count }
        print(
            "NOTES-BENCH name=\(name) utterances=\(transcript.count) words=\(words) chunks=\(result.chunkCount) status=\(result.status.rawValue) points=\(result.verifiedPointCount) dropped=\(result.droppedCount) failedChunks=\(result.failedChunks.count) reduceFailed=\(result.reduceFailed) seconds=\(String(format: "%.1f", seconds)) footprintBeforeMB=\(Self.megabytes(before)) footprintAfterMB=\(Self.megabytes(Self.footprintBytes()))"
        )
    }

    @Test func theCorpusOnARealModel() async throws {
        let url = try #require(Self.modelURL)
        let notes = pipeline(url: url)
        for corpus in try NotesCorpusCase.all() {
            let transcript = corpus.transcript
            let before = Self.footprintBytes()
            let clock = ContinuousClock()
            var result: NotesResult?
            let elapsed = try await clock.measure { result = try await notes.run(utterances: transcript) }
            let finished = try #require(result)
            report(
                corpus.name, transcript: transcript, result: finished, seconds: elapsed.seconds, before: before)

            NotesInvariants.check(finished, transcript: transcript, context: corpus.name)
            let lowered = (finished.markdown ?? "").lowercased()
            for text in corpus.expect.drop {
                #expect(!lowered.contains(text.lowercased()), "\(corpus.name): \(text) got into the notes")
            }
            // The model answered something usable: the dropped count is reported next to real notes.
            #expect(finished.status != .failed, "\(corpus.name): the notes failed")
        }
    }

    @Test func aLongMeetingOnARealModel() async throws {
        let url = try #require(Self.modelURL)
        let environment = ProcessInfo.processInfo.environment
        var transcript: [NotesUtterance]
        var name = "long"
        if let path = environment["LINTEL_NOTES_TRANSCRIPT"] {
            transcript = try NotesCorpusCase.plainTranscript(at: URL(filePath: path))
            name = "own-transcript"
        } else {
            let base = try NotesCorpusCase.longMeeting()
            let repeats = max(1, Int(environment["LINTEL_NOTES_LONG_REPEAT"] ?? "") ?? 1)
            let span = (base.last?.startMs ?? 0) + 17_000
            transcript = (0..<repeats).flatMap { round in
                base.map { NotesUtterance(startMs: $0.startMs + round * span, speaker: $0.speaker, text: $0.text) }
            }
        }
        let notes = pipeline(url: url)
        let before = Self.footprintBytes()
        let clock = ContinuousClock()
        var result: NotesResult?
        let elapsed = try await clock.measure { result = try await notes.run(utterances: transcript) }
        let finished = try #require(result)
        report(name, transcript: transcript, result: finished, seconds: elapsed.seconds, before: before)
        NotesInvariants.check(finished, transcript: transcript, context: name)
    }
}

extension Duration {
    fileprivate var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
