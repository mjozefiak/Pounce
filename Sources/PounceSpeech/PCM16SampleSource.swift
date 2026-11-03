import FluidAudio

/// FluidAudio's random-access audio input over 16-bit samples, converted to `Float` per request (half the memory
/// of an array of `Float`). Lives here because MeetingsPlugin has an `AudioSampleSource` of its own, and a module's
/// own declaration hides FluidAudio's of the same name. Meetings use it for diarization (ADR 0007).
public struct PCM16SampleSource: AudioSampleSource {
    private let samples: [Int16]

    public init(samples: [Int16]) {
        self.samples = samples
    }

    public var sampleCount: Int { samples.count }

    public func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0, !samples.isEmpty else { return }
        let start = max(0, offset)
        guard start < samples.count else { return }
        let available = min(samples.count - start, count)
        for index in 0..<available { destination[index] = Float(samples[start + index]) / 32_768 }
    }
}
