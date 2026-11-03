import Foundation

/// The session's state in memory (spec: Phasing, "Stany"). `idle` has no row in the database; the others map
/// to `meeting.status` through `meetingStatus`.
enum MeetingSessionState: Equatable, Sendable {
    case idle
    case recording
    case finishing
    case processing
    case ready
    /// The recording could not be finished (the speech model was unavailable for the deferred segments); the
    /// spool is kept and a later run can complete it.
    case incomplete
    case failed

    var meetingStatus: MeetingStatus? {
        switch self {
        case .idle: nil
        case .recording: .recording
        case .finishing, .processing: .processing
        case .ready: .ready
        case .incomplete: .incomplete
        case .failed: .failed
        }
    }

    var isTerminal: Bool { self == .ready || self == .incomplete || self == .failed }
}

/// Everything the HUD wants to know while a meeting runs. Carries counts and durations, never text or audio.
enum MeetingSessionEvent: Equatable, Sendable {
    case stateChanged(MeetingSessionState)
    /// A 0...1 loudness of one track's latest chunk.
    case level(AudioChannel, Float)
    /// Whole seconds recorded so far.
    case elapsed(seconds: Int)
    /// The speech model is not in memory yet and is being loaded; recording already runs.
    case loadingModel
    case modelLoaded
    /// The speech model could not be taken; `busy` when another model is in use. Segments wait in the spool.
    case modelUnavailable(busy: Bool)
    /// A track could not be started at the beginning (the session continues with the other one).
    case trackUnavailable(AudioChannel)
    /// A track ended while recording (device unplugged, permission revoked); the other one carries on.
    case trackLost(AudioChannel)
    /// A segment was written to the library; `total` is the number of segments saved so far.
    case segmentSaved(AudioChannel, total: Int)
    /// The spool of a track failed; the transcript is still being written.
    case spoolFailed(AudioChannel)
    case databaseWriteFailed
    case lowDisk
    case limitApproaching(secondsLeft: Int)
    case limitReached
    /// Segments are being transcribed from the spool after the meeting; `remaining` is how many are left.
    case replaying(remaining: Int)
    /// The meeting was too short and silent: nothing was stored (message "Nic nie usłyszano").
    case nothingHeard
    case finished(MeetingSessionOutcome)
}

struct MeetingSessionOutcome: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case ready
        case incomplete
        case failed
        /// Shorter than the minimum and without speech: no database row remains.
        case discarded
        /// `finish()` was called on a session that never started.
        case notStarted
    }

    var result: Result
    var meetingID: Int64?
    var segmentCount = 0
    var durationMs = 0
    /// Segments that could not be transcribed.
    var failedSegments = 0
    /// Segments that went through the spool after the meeting (the background queue was full).
    var replayedSegments = 0
    /// Microphone segments dropped as echoes of the system track.
    var echoesDropped = 0
}

enum MeetingSessionError: Error, Equatable {
    case alreadyStarted
    /// Another session holds the gate.
    case anotherSessionActive
    /// No audio source could be started.
    case noAudioInput
    case database
}

/// Limits and thresholds of a session. The defaults are the spec's; tests shorten them.
struct MeetingSessionLimits: Sendable {
    /// The recording ends by itself after this long (spec: 3 h).
    var maximumDuration: Duration = .seconds(3 * 3600)
    /// The countdown starts this long before the end (spec: from 2 h 50 min).
    var warningBefore: Duration = .seconds(10 * 60)
    /// A meeting shorter than this without any speech is discarded (spec: 15 s).
    var discardBelow: Duration = .seconds(15)
    /// Free space needed to start (spec: 1.5 GB).
    var startFreeBytes: Int64 = SpoolFormat.minimumFreeBytes
    /// Below this the recording ends gracefully (spec: 300 MB).
    var stopFreeBytes: Int64 = 300 * 1_024 * 1_024
    /// The free space is read after every this much recorded audio.
    var diskCheckEvery: Duration = .seconds(5)

    static func samples(in duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * SpoolFormat.sampleRate
            + Int(Double(parts.attoseconds) / 1e18 * Double(SpoolFormat.sampleRate))
    }
}
