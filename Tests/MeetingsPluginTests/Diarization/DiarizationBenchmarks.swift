import Foundation
import Testing

@testable import MeetingsPlugin

/// Local only, off by default (like the other benchmarks): the real Community-1 models on a real recording.
/// Runs the offline pipeline over a 16 kHz mono WAV, prints the wall time, the number of speakers and the
/// resident memory before and after, and checks that the models were released. Run it with the network off
/// to confirm nothing is fetched. The result goes into the PR body (spec step 1.6: a 1 h benchmark).
///
/// `LINTEL_DIARIZATION_MODEL_FOLDER=<Models>/diarization-community-1 LINTEL_DIARIZATION_BENCH_AUDIO=meeting.wav swift test --filter DiarizationBenchmarks`
@Suite(
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["LINTEL_DIARIZATION_MODEL_FOLDER"] != nil
            && ProcessInfo.processInfo.environment["LINTEL_DIARIZATION_BENCH_AUDIO"] != nil))
struct DiarizationBenchmarks {
    private static func residentBytes() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
    }

    @Test func diarizesARealRecording() async throws {
        let environment = ProcessInfo.processInfo.environment
        let folder = URL(
            filePath: try #require(environment["LINTEL_DIARIZATION_MODEL_FOLDER"]), directoryHint: .isDirectory)
        let audio = URL(filePath: try #require(environment["LINTEL_DIARIZATION_BENCH_AUDIO"]))
        let samples = try WAVFile.samples(from: Data(contentsOf: audio))
        let source = ArraySource(samples)

        let diarizer = FluidDiarizer(modelFolder: folder)
        let before = Self.residentBytes()
        let started = Date()
        let spans = try await diarizer.diarize(source, maximumSamples: samples.count)
        let elapsed = Date().timeIntervalSince(started)
        let during = Self.residentBytes()
        await diarizer.release()
        let after = Self.residentBytes()

        let minutes = Double(samples.count) / 16_000 / 60
        print(
            "DIARIZATION: \(String(format: "%.1f", minutes)) min of audio in \(String(format: "%.1f", elapsed)) s,"
                + " \(Set(spans.map(\.cluster)).count) speakers, \(spans.count) spans,"
                + " resident MB before/during/after: \(before >> 20)/\(during >> 20)/\(after >> 20)")
        #expect(!spans.isEmpty)
        #expect(await !diarizer.isLoaded)
    }
}

/// An in-memory source of Float chunks (the benchmark has no spool).
private final class ArraySource: AudioSampleSource {
    private let samples: [Float]
    private let position = Mutex_(0)
    let sampleRate = 16_000
    var endState: AudioEndState? { position.value >= samples.count ? .complete : nil }

    init(_ samples: [Float]) { self.samples = samples }

    func nextChunk() throws -> [Float]? {
        let start = position.value
        guard start < samples.count else { return nil }
        let end = min(samples.count, start + 32_000)
        position.value = end
        return Array(samples[start..<end])
    }
}

private final class Mutex_: @unchecked Sendable {
    var value: Int
    init(_ value: Int) { self.value = value }
}
