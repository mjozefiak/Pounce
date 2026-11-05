import Foundation

/// How an audio stream ended.
enum AudioEndState: Equatable, Sendable {
    /// The stream was closed cleanly (a spool's final frame was read).
    case complete
    /// The data ends exactly after a complete frame, but nothing marks the end.
    case missingEndMarker
    /// The data ends inside a frame (a crash during a write); the partial frame is dropped.
    case truncatedMidFrame

    var isClean: Bool { self == .complete }
}

/// A stream of mono audio read in chunks, so a consumer (the diarizer) never needs the audio as a file:
/// plaintext audio is never written to disk. Pull-based and synchronous; implementations are not meant to be
/// shared between concurrent readers.
///
/// A truncated stream is not an error by default (crash recovery wants every complete frame), but it is never
/// hidden: `nextChunk()` returns `nil` at the end and `endState` tells whether that end was clean. A consumer
/// that must not work from partial audio calls `requireCleanEnd()` after the last chunk.
protocol AudioSampleSource: Sendable {
    var sampleRate: Int { get }

    /// `nil` while chunks remain; how the stream ended once `nextChunk()` returned `nil`.
    var endState: AudioEndState? { get }

    /// The next chunk of samples in -1...1, or `nil` at the end. Throws when the data is damaged.
    func nextChunk() throws -> [Float]?
}

extension AudioSampleSource {
    /// Throws `SpoolError.endedEarly` unless the stream ended cleanly. Call it after `nextChunk()` returned `nil`.
    func requireCleanEnd() throws {
        guard let end = endState, end.isClean else { throw SpoolError.endedEarly(endState ?? .missingEndMarker) }
    }
}
