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

/// The memory a diarization run may use. FluidAudio's offline pipeline reads its input at random positions
/// (windows overlap and embeddings are taken from spans), so a sequential stream cannot feed it; the samples
/// of **one track at a time** are therefore held in memory as 16-bit integers (2 bytes a sample, half of the
/// `Float32` an array source would need). See ADR 0007.
///
/// The default allows the longest meeting (3 h) plus ten minutes, about 365 MB of samples. **The value is not
/// measured**: FluidAudio's own working memory on top of the samples (segmentation batches, embeddings per
/// window) is unknown for 3 h and is the open item of spike 0.0 (ADR 0007); the benchmark test
/// (`POUNCE_DIARIZATION_BENCH_AUDIO`) is where it is measured.
struct DiarizationBudget: Equatable, Sendable {
    static let defaultMaximumSamples = (3 * 3_600 + 10 * 60) * SpoolFormat.sampleRate

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

    /// Reads the whole source. Throws `overBudget` as soon as a chunk would take the buffer past `maximumSamples`.
    static func read(from source: any AudioSampleSource, maximumSamples: Int) throws -> DiarizationAudioBuffer {
        var samples: [Int16] = []
        while let chunk = try source.nextChunk() {
            if samples.count + chunk.count > maximumSamples {
                throw DiarizationError.overBudget(maximumSamples: maximumSamples)
            }
            samples.reserveCapacity(samples.count + chunk.count)
            for value in chunk {
                samples.append(Int16(max(-32_768, min(32_767, (value * 32_768).rounded()))))
            }
        }
        return DiarizationAudioBuffer(samples: samples)
    }

    var durationMs: Int { samples.count * 1_000 / SpoolFormat.sampleRate }
}
