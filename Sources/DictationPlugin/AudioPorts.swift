import Foundation

/// 16 kHz mono `Float32` audio, the format every part of dictation works in.
enum AudioFormat {
    static let sampleRate = 16_000
}

/// Where audio comes from: the microphone in the app, a prepared buffer in tests. Audio exists only in
/// memory.
protocol AudioInput: Sendable {
    /// Starts capturing. The stream yields chunks of any length until `stop()`, or ends early when the
    /// device disappears. `onLevel` gets a 0...1 loudness for every chunk, for the HUD.
    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]>
    func stop() async
}

/// Asks for the microphone, which happens only when the user presses the shortcut (Pounce never asks by
/// itself).
protocol MicrophoneAuthorizer: Sendable {
    func status() -> MicrophoneAccess
    /// Shows the system prompt when the answer is not known yet. Returns whether access was granted.
    func requestAccess() async -> Bool
}

enum MicrophoneAccess: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

/// One piece of transcribed speech.
struct TranscriptSegment: Equatable, Sendable {
    let text: String
}

/// The speech to text model. Implementations load from a folder `ModelManager` vouches for and never
/// download anything themselves.
protocol SpeechEngine: Sendable {
    var isLoaded: Bool { get async }
    func load(modelFolder: URL) async throws
    func transcribe(_ samples: [Float]) async throws -> TranscriptSegment
    func unload() async
}

struct VADEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case speechStart
        case speechEnd
    }

    let kind: Kind
    /// Sample index counted from the first sample of the session.
    let sampleIndex: Int
}

/// Finds where speech starts and ends in a live stream. One instance per recording.
protocol VoiceActivityDetector: Sendable {
    /// Feeds samples of any length and returns the boundaries found so far.
    func process(_ samples: [Float]) async throws -> [VADEvent]
}

/// The recording's samples in memory, dropping what has been handed to the engine. Indexes are counted from
/// the first sample of the session and never shift.
struct SampleStore {
    private(set) var base = 0
    private var samples: [Float] = []

    /// Samples received so far, including those already dropped.
    var count: Int { base + samples.count }

    /// Samples still held.
    var heldCount: Int { samples.count }

    mutating func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
    }

    /// The samples of `range`, clamped to what is still held.
    func slice(_ range: Range<Int>) -> [Float] {
        let lower = max(range.lowerBound, base) - base
        let upper = min(range.upperBound, count) - base
        guard lower < upper else { return [] }
        return Array(samples[lower..<upper])
    }

    /// Drops everything before `index`.
    mutating func discard(before index: Int) {
        let drop = min(max(index - base, 0), samples.count)
        guard drop > 0 else { return }
        samples.removeFirst(drop)
        base += drop
    }
}
