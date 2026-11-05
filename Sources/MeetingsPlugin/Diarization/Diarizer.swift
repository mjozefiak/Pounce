import Foundation

/// One stretch of one speaker on one track, as the diarizer reports it. `cluster` is only meaningful inside
/// its own track (two tracks are diarized separately, so "S1" of the microphone is not "S1" of the system track).
struct DiarizedSpan: Equatable, Sendable {
    let cluster: String
    let startMs: Int
    let endMs: Int
}

enum DiarizationError: Error, Equatable {
    /// The track holds more samples than the memory budget allows; diarization is skipped for the meeting.
    case overBudget(maximumSamples: Int)
    /// The model folder is missing a file or a model could not be opened. Nothing is downloaded to repair it.
    case modelsUnavailable
    case failed
}

/// The longest track a diarization run accepts, and so what its memory use is bounded by.
///
/// FluidAudio's offline pipeline reads its input at random positions (windows overlap and embeddings are taken
/// from spans), so a sequential stream cannot feed it; the samples of **one track at a time** are held in
/// memory as 16-bit integers (2 bytes a sample, half of the `Float32` an array source would need). The samples
/// are the smaller part, though: the clustering (AHC and VBx) works on the embeddings of the whole track,
/// about one per two seconds per slot, and its distance matrices grow roughly with the square of that number.
/// The budget is therefore a **duration**, not a sample count.
///
/// **UNMEASURED, tighten after the benchmark.** 90 minutes is a conservative guess, not a measurement: the
/// peak memory of FluidAudio for 1 h and 3 h is the open item of spike 0.0 (ADR 0007, `docs/perf.md`) and is
/// what `DiarizationBenchmarks` (`LINTEL_DIARIZATION_BENCH_AUDIO`) measures. Until it has run, a track longer
/// than this falls back to the channel labels instead of risking the process.
struct DiarizationBudget: Equatable, Sendable {
    /// UNMEASURED, tighten (or raise) after the benchmark. See the type's comment.
    static let unmeasuredMaximumDuration: Duration = .seconds(90 * 60)

    static let defaultMaximumSamples = Int(unmeasuredMaximumDuration.components.seconds) * SpoolFormat.sampleRate

    var maximumSamplesPerTrack: Int

    init(maximumSamplesPerTrack: Int = Self.defaultMaximumSamples) {
        self.maximumSamplesPerTrack = max(0, maximumSamplesPerTrack)
    }
}

/// A speaker diarizer for one track at a time. An implementation may hold large model state while it works;
/// `release()` frees it, and the finalizer calls it right after the last track (also on failure).
protocol Diarizer: Sendable {
    /// Written to `meeting.diarization_model_id`.
    var modelID: String { get }

    /// Speaker spans of the whole track. Throws `overBudget` when the track has more than `maximumSamples`
    /// samples, before it holds more than that in memory.
    func diarize(_ source: any AudioSampleSource, maximumSamples: Int) async throws -> [DiarizedSpan]

    func release() async
}

/// The samples of one track in memory as `Int16`, read from an `AudioSampleSource` (the decrypting
/// `SpoolReader`): no plaintext file exists at any point.
struct DiarizationAudioBuffer: Sendable {
    let samples: [Int16]

    /// Reads the whole source. Throws `overBudget` as soon as a chunk would take the buffer past `maximumSamples`
    /// and `CancellationError` between chunks when the task is cancelled. Blocking: call it through
    /// `readOffTheCaller` from async code.
    static func read(from source: any AudioSampleSource, maximumSamples: Int) throws -> DiarizationAudioBuffer {
        var samples: [Int16] = []
        while let chunk = try source.nextChunk() {
            try Task.checkCancellation()
            if samples.count + chunk.count > maximumSamples {
                throw DiarizationError.overBudget(maximumSamples: maximumSamples)
            }
            // Appended without `reserveCapacity` per chunk: that would copy the array on every chunk; the
            // geometric growth of `append` keeps the copying linear.
            for value in chunk {
                samples.append(Int16(max(-32_768, min(32_767, (value * 32_768).rounded()))))
            }
        }
        try Task.checkCancellation()
        return DiarizationAudioBuffer(samples: samples)
    }

    /// `read` on the global executor, so that the blocking read and decryption of a long spool never occupy
    /// the caller's actor. Cancellation of the calling task reaches the loop (same task).
    @concurrent
    static func readOffTheCaller(from source: any AudioSampleSource, maximumSamples: Int) async throws
        -> DiarizationAudioBuffer
    {
        try read(from: source, maximumSamples: maximumSamples)
    }

    var durationMs: Int { samples.count * 1_000 / SpoolFormat.sampleRate }
}
