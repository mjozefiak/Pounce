import Foundation

/// A stream of mono audio read in chunks, so a consumer (the diarizer) never needs the audio as a file:
/// plaintext audio is never written to disk. Pull-based and synchronous; implementations are not meant to be
/// shared between concurrent readers.
protocol AudioSampleSource: Sendable {
    var sampleRate: Int { get }

    /// The next chunk of samples in -1...1, or `nil` at the end. Throws when the data is damaged.
    func nextChunk() throws -> [Float]?
}
