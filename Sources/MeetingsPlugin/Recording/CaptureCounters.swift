import Foundation
import LintelPersistence
import LintelSpeech
import Synchronization

/// What the system source saw of its tap (numbers only). Filled outside the audio callback; the ring's drop
/// counter is the existing atomic, read only when a snapshot is taken.
struct SystemCaptureStats: Equatable, Sendable {
    var tapsRecreated = 0
    var recreateFailures = 0
    var formatChanges = 0
    var timelineResyncs = 0
    var outputChangesNotObserved = 0
    /// Samples of silence the pipeline inserted for missing buffers or while a tap was down.
    var silenceInsertedSamples = 0
    /// Tap buffers dropped because the ring was full or did not fit.
    var ringDropped = 0

    /// A hole in the recorded audio, in the sense of `meeting.audio_gap`.
    var hasGap: Bool { silenceInsertedSamples > 0 || ringDropped > 0 || recreateFailures > 0 }
}

/// Implemented by audio inputs that can report `SystemCaptureStats` (the system source).
protocol CaptureStatsProviding: Sendable {
    var captureStats: SystemCaptureStats { get }
}

/// Counters of one channel of one meeting. Numbers only: no text, speaker, title or device name.
struct ChannelCounters: Equatable, Codable, Sendable {
    /// Samples (16 kHz) that arrived, including silence inserted on a resume.
    var recordedSamples = 0
    var vadSegmentsOpened = 0
    var vadSegmentsClosed = 0
    /// A speech end with no open segment.
    var vadUnmatchedEnds = 0
    /// A range of zero length: nothing was sent.
    var emptyRanges = 0
    /// Segments closed because the track was lost or the meeting ended while speech was open.
    var forcedCloses = 0
    /// Segments held back (not sent) because the background queue already had its limit of audio waiting.
    var backlogDeferred = 0
    /// Segments shorter than 500 ms that were sent (descriptive; there is no minimum length).
    var shortSegments = 0
    /// Segments cut at the model window because speech went on.
    var hardCuts = 0
    var segmentsSent = 0
    /// Samples of those segments: the speech sent to the engine.
    var speechSamplesSent = 0
    /// The engine returned no text; the segment was dropped.
    var emptyResults = 0
    /// Segments with text.
    var textResults = 0
    /// No speech model yet, or none available: waits in the spool.
    var deferredNoModel = 0
    /// The background queue held its limit (`.spool` result): waits in the spool.
    var spoolResults = 0
    var failedResults = 0
    var replayedText = 0
    var replayedEmpty = 0
    var replayedFailed = 0
    var interruptions = 0
    var resumes = 0
    var lost = 0
    /// Samples of silence put in place of audio during a resume.
    var gapFillSamples = 0
    // System source only (zero on the microphone).
    var tapsRecreated = 0
    var recreateFailures = 0
    var formatChanges = 0
    var timelineResyncs = 0
    var outputChangesNotObserved = 0
    var silenceInsertedSamples = 0
    var ringDropped = 0

    mutating func apply(_ stats: SystemCaptureStats) {
        tapsRecreated = stats.tapsRecreated
        recreateFailures = stats.recreateFailures
        formatChanges = stats.formatChanges
        timelineResyncs = stats.timelineResyncs
        outputChangesNotObserved = stats.outputChangesNotObserved
        silenceInsertedSamples = stats.silenceInsertedSamples
        ringDropped = stats.ringDropped
    }
}

/// Counters of one meeting, per channel, plus the numbers that belong to the meeting.
struct CaptureCounters: Equatable, Codable, Sendable {
    var meetingID: Int64 = 0
    var durationMs = 0
    var mic = ChannelCounters()
    var system = ChannelCounters()
    /// The speech model was held by another user when the meeting needed it.
    var modelBusy = 0
    var modelUnavailable = 0
    /// `audio_gap` was written for this meeting while it was recording.
    var audioGapWritten = false

    subscript(channel: AudioChannel) -> ChannelCounters {
        get { channel == .mic ? mic : system }
        set { if channel == .mic { mic = newValue } else { system = newValue } }
    }
}

/// The plain-text report for *Copy diagnostics* and the end-of-meeting log line: counts and identifiers of the
/// channels (`mic`, `system`) only.
enum CaptureDiagnostics {
    static func milliseconds(_ samples: Int) -> Int { samples * 1_000 / AudioFormat.sampleRate }

    static func report(_ meetings: [CaptureCounters]) -> String {
        var lines = ["Lintel Meetings capture diagnostics", "Meetings listed: \(meetings.count)"]
        for counters in meetings { lines += section(counters) }
        return lines.joined(separator: "\n")
    }

    static func section(_ counters: CaptureCounters) -> [String] {
        var lines = [
            "",
            "Meeting \(counters.meetingID): \(counters.durationMs / 1_000) s",
            "  Speech model busy: \(counters.modelBusy), unavailable: \(counters.modelUnavailable)",
            "  Audio gap written while recording: \(counters.audioGapWritten ? "yes" : "no")",
        ]
        for channel in AudioChannel.allCases {
            let c = counters[channel]
            lines += [
                "  [\(channel.rawValue)] recorded: \(milliseconds(c.recordedSamples)) ms, "
                    + "speech sent to engine: \(milliseconds(c.speechSamplesSent)) ms",
                "  [\(channel.rawValue)] VAD segments opened: \(c.vadSegmentsOpened), closed: \(c.vadSegmentsClosed), "
                    + "unmatched ends: \(c.vadUnmatchedEnds), empty ranges: \(c.emptyRanges), "
                    + "under 500 ms: \(c.shortSegments), hard cuts: \(c.hardCuts), forced closes: \(c.forcedCloses), "
                    + "held back by the backlog: \(c.backlogDeferred)",
                "  [\(channel.rawValue)] segments sent: \(c.segmentsSent), with text: \(c.textResults), "
                    + "empty results dropped: \(c.emptyResults), no model: \(c.deferredNoModel), "
                    + "spool results: \(c.spoolResults), failed: \(c.failedResults)",
                "  [\(channel.rawValue)] replay with text: \(c.replayedText), empty: \(c.replayedEmpty), "
                    + "failed: \(c.replayedFailed)",
                "  [\(channel.rawValue)] interruptions: \(c.interruptions), resumes: \(c.resumes), lost: \(c.lost), "
                    + "silence put in place of a gap: \(milliseconds(c.gapFillSamples)) ms",
            ]
            if channel == .system {
                lines.append(
                    "  [system] taps recreated: \(c.tapsRecreated), recreate failures: \(c.recreateFailures), "
                        + "format changes: \(c.formatChanges), timeline resyncs: \(c.timelineResyncs), "
                        + "output changes not observed: \(c.outputChangesNotObserved), "
                        + "silence inserted: \(milliseconds(c.silenceInsertedSamples)) ms, "
                        + "ring buffers dropped: \(c.ringDropped)")
            }
        }
        return lines
    }
}

/// The last meetings' counters as JSON in `Plugins/meetings/capture-counters.json` (0600, atomic). Numbers only;
/// it needs no migration and goes with `eraseData()` (the whole folder).
final class CaptureCountersStore: Sendable {
    static let fileName = "capture-counters.json"
    static let keep = 20

    private let url: URL
    private let lock = Mutex(())

    init(directory: URL) {
        url = directory.appending(path: Self.fileName)
    }

    func load() -> [CaptureCounters] {
        lock.withLock { _ in read() }
    }

    func record(_ counters: CaptureCounters) throws {
        try lock.withLock { _ in
            var all = read().filter { $0.meetingID != counters.meetingID }
            all.append(counters)
            if all.count > Self.keep { all.removeFirst(all.count - Self.keep) }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try AtomicFile.write(try JSONEncoder().encode(all), to: url)
        }
    }

    private func read() -> [CaptureCounters] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([CaptureCounters].self, from: data)) ?? []
    }
}
