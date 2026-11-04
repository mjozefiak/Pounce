import Foundation
import PounceSpeech
import os

/// What `MeetingResumer` reports while it works. Counts only: never text, never audio.
enum ResumeEvent: Equatable, Sendable {
    case scanning(AudioChannel)
    /// Segments are being transcribed from the spool; `remaining` is how many are left.
    case replaying(remaining: Int)
    case loadingModel
    /// The speakers are being recognised and the meeting is being closed.
    case finalizing
    case finished(ResumeOutcome)
}

enum ResumeOutcome: Equatable, Sendable {
    /// Transcript complete, speakers assigned, meeting `ready`, spool deleted.
    case ready
    /// Something could not be finished. The meeting is `incomplete` and its spool is kept.
    case incomplete(Reason)
    /// The caller cancelled; whatever was written stays, the status is unchanged.
    case cancelled
    /// The spool gave an I/O error: nothing was concluded or changed, try again later.
    case unavailable
    /// The library could not be written; nothing more can be done now.
    case databaseUnwritable
    /// Nothing is left to build on: no spool and no segments (`failed`).
    case failed
    /// The meeting is not `processing` or `incomplete`.
    case notResumable

    enum Reason: Equatable, Sendable {
        /// The speech model is not installed or busy; `busy` when another model is in use.
        case modelUnavailable(busy: Bool)
        /// This many segments could not be transcribed or read back from the spool (or tracks could not be
        /// opened). `finish(meetingID:acceptGap: true)` closes the meeting anyway, with the gap recorded.
        case unfinished(Int)
        /// The spool exists but cannot be read for good (for example the Keychain key was recreated). It is
        /// kept, not deleted; "finish anyway" (`acceptGap`) closes the meeting from its transcript.
        case audioUnreadable
    }
}

/// What the recovery job and the library need from the thing that finishes a meeting.
protocol MeetingResuming: Sendable {
    /// `acceptGap`: the user agreed to close the meeting although some audio could not be transcribed or read
    /// (the meeting is marked as having a gap). Automatic recovery never sets it.
    func resume(
        _ meeting: RecoverableMeeting, acceptGap: Bool, events: @escaping @Sendable (ResumeEvent) -> Void
    ) async -> ResumeOutcome
}

extension MeetingResuming {
    func resume(_ meeting: RecoverableMeeting, events: @escaping @Sendable (ResumeEvent) -> Void) async
        -> ResumeOutcome
    {
        await resume(meeting, acceptGap: false, events: events)
    }
}

/// The speech engine to use for the replay.
struct ResumeSpeech: Sendable {
    let engine: any SpeechEngine
    let modelID: String
    let folder: URL
}

/// Finishes a meeting from its spool after a crash or on "Dokończ" (spec step 1.7). It drives the same
/// primitives as `MeetingSession`'s replay (`SpoolReader`, a voice activity detector per track,
/// `SpeechEngineLease`, `MeetingsStore` inserts), then runs the `MeetingFinalizer` hook, marks the meeting
/// `ready` and only then deletes the spool.
///
/// - The speech that is missing from the library is found by running voice activity detection over the spool
///   (silence is never transcribed) and keeping the ranges that stored segments of that track do not already
///   cover, so running it again after a partial run neither duplicates nor skips text.
/// - The system track goes first so the microphone's echo check sees all of it.
/// - The spool is never deleted before the meeting really is `ready`. A segment that cannot be transcribed or
///   read back, or a model that is not available, leaves the meeting `incomplete` with the spool kept.
/// - Transcript text and audio never reach a log: only counts.
struct MeetingResumer: MeetingResuming {
    let store: MeetingsStore
    let keys: MeetingKeys
    let spool: SpoolStorage
    let makeVAD: @Sendable () -> any VoiceActivityDetector
    /// `nil` when no speech model is installed.
    let speech: @Sendable () async -> ResumeSpeech?
    let lease: SpeechEngineLease
    let keepWarm: @Sendable () -> Duration
    /// `MeetingFinalizer.hook`: diarization and speaker assignment; never throws.
    let finalize: @Sendable (Int64, UUID) async -> Void
    let echo: EchoSuppressor
    let now: @Sendable () -> Date
    let logger: Logger

    init(
        store: MeetingsStore, keys: MeetingKeys, spool: SpoolStorage,
        makeVAD: @escaping @Sendable () -> any VoiceActivityDetector,
        speech: @escaping @Sendable () async -> ResumeSpeech?, lease: SpeechEngineLease = .shared,
        keepWarm: @escaping @Sendable () -> Duration = { .seconds(600) },
        finalize: @escaping @Sendable (Int64, UUID) async -> Void, echo: EchoSuppressor = EchoSuppressor(),
        now: @escaping @Sendable () -> Date = { Date() },
        logger: Logger = Logger(subsystem: "app.pounce", category: "meetings")
    ) {
        self.store = store
        self.keys = keys
        self.spool = spool
        self.makeVAD = makeVAD
        self.speech = speech
        self.lease = lease
        self.keepWarm = keepWarm
        self.finalize = finalize
        self.echo = echo
        self.now = now
        self.logger = logger
    }

    func resume(
        _ meeting: RecoverableMeeting, acceptGap: Bool, events: @escaping @Sendable (ResumeEvent) -> Void
    ) async -> ResumeOutcome {
        let outcome = await run(meeting, acceptGap: acceptGap, events: events)
        events(.finished(outcome))
        return outcome
    }

    // MARK: Run

    private func run(
        _ meeting: RecoverableMeeting, acceptGap: Bool, events: @escaping @Sendable (ResumeEvent) -> Void
    ) async -> ResumeOutcome {
        guard meeting.status == .processing || meeting.status == .incomplete else { return .notResumable }
        guard let uuid = meeting.uuid else {
            return await closeWithoutAudio(meeting, uuid: nil, condition: .absent, acceptGap: acceptGap)
        }
        let condition = spool.condition(of: uuid, keys: keys)
        switch condition {
        case .indeterminate:
            logger.error("The spool of a meeting could not be checked; nothing was changed")
            return .unavailable
        case .absent, .unreadable:
            return await closeWithoutAudio(meeting, uuid: uuid, condition: condition, acceptGap: acceptGap)
        case .readable:
            break
        }

        // 1. Where is speech that the library does not have?
        let stored: [AudioChannel: [(start: Int, end: Int)]]
        var scans: [AudioChannel: TrackScan] = [:]
        do {
            let refs = try store.segmentRefs(meetingID: meeting.id)
            stored = Dictionary(grouping: refs, by: \.channel).mapValues { $0.map { ($0.startMs, $0.endMs) } }
        } catch {
            logger.error("The segments of a meeting could not be read")
            return .databaseUnwritable
        }
        var missing: [AudioChannel: [Range<Int>]] = [:]
        var gaps = 0
        for channel in [AudioChannel.system, .mic] {
            guard let track = SpoolTrack(rawValue: channel.rawValue), spool.hasTrackFile(of: uuid, track) else {
                continue
            }
            events(.scanning(channel))
            do {
                let scan = try await scan(track, uuid: uuid)
                scans[channel] = scan
                if scan.damaged { gaps += 1 }
                missing[channel] = Self.uncovered(scan.ranges, by: stored[channel] ?? [])
            } catch is CancellationError {
                return .cancelled
            } catch is ScanFailure {
                // The detector (a model) failed, not the audio: nothing is concluded about the track.
                logger.error("Recovery: the voice activity detector failed")
                return await settle(
                    meeting, uuid: uuid, outcome: .incomplete(.modelUnavailable(busy: false)), scans: scans)
            } catch {
                // The track cannot be opened at all (the other one could, or a 0-byte file): its audio is lost.
                gaps += 1
            }
        }

        // 2. Transcribe it.
        let total = missing.values.reduce(0) { $0 + $1.count }
        if total > 0 {
            switch await replay(meeting, uuid: uuid, missing: missing, total: total, events: events) {
            case .done(let lost):
                gaps += lost
            case .stop(let outcome):
                return await settle(meeting, uuid: uuid, outcome: outcome, scans: scans)
            }
        }
        if Task.isCancelled { return .cancelled }
        guard gaps == 0 || acceptGap else {
            return await settle(meeting, uuid: uuid, outcome: .incomplete(.unfinished(gaps)), scans: scans)
        }

        // 3. Speakers, then ready, then (and only then) the audio goes.
        events(.finalizing)
        await finalize(meeting.id, uuid)
        if Task.isCancelled { return .cancelled }
        return markReady(meeting, uuid: uuid, scans: scans, gap: gaps > 0)
    }

    // MARK: Scan

    /// The voice activity detector failed (as opposed to the spool being damaged).
    private struct ScanFailure: Error {}

    private struct TrackScan {
        var ranges: [Range<Int>] = []
        var samples = 0
        /// The stream ended with a damaged frame (not just a truncated tail): audio beyond it is lost.
        var damaged = false
    }

    /// Runs a voice activity detector over the whole track, a chunk at a time, and returns the speech ranges
    /// (at most `MeetingSession.longestSegment` long) in samples.
    private func scan(_ track: SpoolTrack, uuid: UUID) async throws -> TrackScan {
        let reader = try SpoolReader(file: spool.file(for: uuid, track: track), meeting: uuid, track: track, keys: keys)
        let vad = makeVAD()
        let longest = MeetingSession.longestSegment
        var scan = TrackScan()
        var start: Int?
        func close(_ range: Range<Int>) { if !range.isEmpty { scan.ranges.append(range) } }
        do {
            while let chunk = try reader.nextChunk() {
                try Task.checkCancellation()
                scan.samples += chunk.count
                for event in try await vad.process(chunk) {
                    switch event.kind {
                    case .speechStart:
                        if start == nil { start = event.sampleIndex }
                    case .speechEnd:
                        if let begin = start {
                            close(begin..<max(begin, event.sampleIndex))
                            start = nil
                        }
                    }
                }
                while let begin = start, scan.samples - begin > longest {
                    close(begin..<begin + longest)
                    start = begin + longest
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch is SpoolError {
            scan.damaged = true
            logger.error("A spool track is damaged; the audio after the damage is lost")
        } catch {
            throw ScanFailure()
        }
        if let begin = start { close(begin..<max(begin, scan.samples)) }
        return scan
    }

    /// The ranges that stored segments cover by less than half. Stored segments come from the same kind of
    /// range (a segment is stored only when it had text), so a range is "known" when it mostly overlaps one.
    static func uncovered(_ ranges: [Range<Int>], by stored: [(start: Int, end: Int)]) -> [Range<Int>] {
        ranges.filter { range in
            let start = range.lowerBound * 1_000 / AudioFormat.sampleRate
            let end = range.upperBound * 1_000 / AudioFormat.sampleRate
            let covered = stored.reduce(0) { $0 + max(0, min($1.end, end) - max($1.start, start)) }
            return covered * 2 < max(1, end - start)
        }
    }

    // MARK: Replay

    private enum ReplayResult {
        /// Every range was tried; `lost` could not be transcribed or read back.
        case done(lost: Int)
        case stop(ResumeOutcome)
    }

    private func replay(
        _ meeting: RecoverableMeeting, uuid: UUID, missing: [AudioChannel: [Range<Int>]], total: Int,
        events: @escaping @Sendable (ResumeEvent) -> Void
    ) async -> ReplayResult {
        guard let setup = await speech() else {
            logger.notice("Recovery: the speech model is not installed")
            return .stop(.incomplete(.modelUnavailable(busy: false)))
        }
        let handle: SpeechLease
        do {
            handle = try await lease.acquire(
                modelID: setup.modelID, folder: setup.folder, engine: setup.engine, priority: .background,
                keepWarm: keepWarm, onLoading: { events(.loadingModel) })
        } catch {
            let busy = (error as? ModelLeaseError) == .busy
            logger.error("Recovery: the speech model is unavailable (busy: \(busy, privacy: .public))")
            return .stop(.incomplete(.modelUnavailable(busy: busy)))
        }

        var systemText: [TrackSegment] = []
        do {
            systemText = try store.trackSegments(meetingID: meeting.id, channel: .system)
        } catch {
            await handle.release()
            return .stop(.databaseUnwritable)
        }
        var state = ReplayState(remaining: total)
        for channel in [AudioChannel.system, .mic] {
            guard let ranges = missing[channel], !ranges.isEmpty,
                let track = SpoolTrack(rawValue: channel.rawValue)
            else { continue }
            let result = await replay(
                ranges.sorted { $0.lowerBound < $1.lowerBound }, channel: channel, track: track, meeting: meeting,
                uuid: uuid, handle: handle, systemText: &systemText, state: &state, events: events)
            if let result {
                await handle.release()
                return .stop(result)
            }
        }
        await handle.release()
        logger.notice(
            "Recovery replayed \(state.transcribed, privacy: .public) segments, \(state.lost, privacy: .public) lost")
        return .done(lost: state.lost)
    }

    private struct ReplayState {
        var remaining: Int
        var transcribed = 0
        var lost = 0
    }

    /// Streams one track's spool once, handing each missing range to the engine as soon as its audio has
    /// passed. Returns an outcome only when the whole run must stop (cancellation, a library that cannot be
    /// written).
    private func replay(
        _ ranges: [Range<Int>], channel: AudioChannel, track: SpoolTrack, meeting: RecoverableMeeting, uuid: UUID,
        handle: SpeechLease, systemText: inout [TrackSegment], state: inout ReplayState,
        events: @escaping @Sendable (ResumeEvent) -> Void
    ) async -> ResumeOutcome? {
        guard
            let reader = try? SpoolReader(
                file: spool.file(for: uuid, track: track), meeting: uuid, track: track, keys: keys)
        else {
            state.lost += ranges.count
            state.remaining -= ranges.count
            return nil
        }
        var index = 0
        var position = 0
        var window: [Float] = []

        func handleRange(_ range: Range<Int>, windowStart: Int) async -> ResumeOutcome? {
            events(.replaying(remaining: state.remaining))
            defer { state.remaining -= 1 }
            let from = max(0, range.lowerBound - windowStart)
            let to = min(window.count, range.upperBound - windowStart)
            guard from < to else {
                state.lost += 1
                return nil
            }
            let text: String
            do {
                switch try await handle.transcribe(Array(window[from..<to])) {
                case .transcript(let segment): text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                case .spool:
                    state.lost += 1
                    return nil
                }
            } catch {
                logger.error("A segment failed to transcribe during recovery")
                state.lost += 1
                return nil
            }
            guard !text.isEmpty else { return nil }
            let segment = TrackSegment(
                track: channel == .system ? .system : .microphone,
                startMs: Int64(range.lowerBound * 1_000 / AudioFormat.sampleRate),
                endMs: Int64(range.upperBound * 1_000 / AudioFormat.sampleRate), text: text)
            if channel == .mic, echo.isEcho(segment, of: systemText) { return nil }
            do {
                try store.insertSegment(
                    meetingID: meeting.id, channel: channel, startMs: Int(segment.startMs), endMs: Int(segment.endMs),
                    text: text)
            } catch {
                logger.error("A recovered segment could not be saved")
                return .databaseUnwritable
            }
            if channel == .system { systemText.append(segment) }
            state.transcribed += 1
            return nil
        }

        do {
            while index < ranges.count, let chunk = try reader.nextChunk() {
                if Task.isCancelled { return .cancelled }
                window += chunk
                position += chunk.count
                while index < ranges.count, ranges[index].upperBound <= position {
                    if let stop = await handleRange(ranges[index], windowStart: position - window.count) {
                        return stop
                    }
                    index += 1
                }
                if index < ranges.count {
                    let drop = min(max(0, ranges[index].lowerBound - (position - window.count)), window.count)
                    window.removeFirst(drop)
                } else {
                    window = []
                }
            }
        } catch {
            logger.error("A spool track could not be read back during recovery")
            state.lost += ranges.count - index
            state.remaining -= ranges.count - index
            return nil
        }
        // The stream ended before the last ranges did (a truncated tail): transcribe what exists.
        while index < ranges.count {
            if Task.isCancelled { return .cancelled }
            if let stop = await handleRange(ranges[index], windowStart: position - window.count) { return stop }
            index += 1
        }
        return nil
    }

    // MARK: Ending

    /// `incomplete` outcomes: a meeting that was `processing` becomes `incomplete` so it never hangs; the
    /// spool is kept and its seven days start now.
    private func settle(
        _ meeting: RecoverableMeeting, uuid: UUID, outcome: ResumeOutcome, scans: [AudioChannel: TrackScan]
    ) async -> ResumeOutcome {
        if outcome == .cancelled || outcome == .databaseUnwritable { return outcome }
        if meeting.status == .processing {
            do {
                let duration = max(
                    meeting.durationMs, scans.values.map { $0.samples * 1_000 / AudioFormat.sampleRate }.max() ?? 0)
                try store.setStatus(
                    meeting.id, status: .incomplete,
                    endedAt: meeting.endedAt ?? meeting.startedAt.addingTimeInterval(Double(duration) / 1_000),
                    durationMs: duration)
                spool.touch(meeting: uuid, at: now())
            } catch {
                logger.error("The meeting could not be marked incomplete")
                return .databaseUnwritable
            }
        }
        return outcome
    }

    /// The spool is missing or unreadable for good.
    /// - Nothing stored: nothing is left to build on (`failed`); an unreadable spool is kept to age out.
    /// - `absent` spool with segments: the transcript is all there is, so the meeting becomes `ready` with the
    ///   gap recorded (completeness cannot be verified).
    /// - `unreadable` spool with segments: **the spool is kept** and the meeting is not reported ready (the
    ///   user may fix the Keychain, and Q7 deletes audio only after successful processing). Only when the user
    ///   accepts the gap does the meeting close from its transcript, and the spool goes only if its removal is
    ///   confirmed.
    private func closeWithoutAudio(
        _ meeting: RecoverableMeeting, uuid: UUID?, condition: SpoolCondition, acceptGap: Bool
    ) async -> ResumeOutcome {
        do {
            guard meeting.segmentCount > 0 else {
                try store.setRecovered(
                    meeting.id, status: .failed, endedAt: nil, durationMs: meeting.durationMs,
                    audioDeleted: condition == .absent && meeting.audioState != .deleted)
                return .failed
            }
            if condition == .unreadable, !acceptGap, let uuid {
                return await settle(meeting, uuid: uuid, outcome: .incomplete(.audioUnreadable), scans: [:])
            }
            if let uuid { await finalize(meeting.id, uuid) }
            if Task.isCancelled { return .cancelled }
            let duration = max(meeting.durationMs, try store.lastSegmentEndMs(meetingID: meeting.id))
            let removed = uuid.map { spool.removeConfirmed(meeting: $0, keys: keys) } ?? true
            try store.setRecovered(
                meeting.id, status: .ready,
                endedAt: meeting.endedAt ?? meeting.startedAt.addingTimeInterval(Double(duration) / 1_000),
                durationMs: duration, audioDeleted: removed, gap: true)
            return .ready
        } catch {
            logger.error("A meeting without readable audio could not be closed")
            return .databaseUnwritable
        }
    }

    private func markReady(_ meeting: RecoverableMeeting, uuid: UUID, scans: [AudioChannel: TrackScan], gap: Bool)
        -> ResumeOutcome
    {
        let scanned = scans.values.map { $0.samples * 1_000 / AudioFormat.sampleRate }.max() ?? 0
        let stored = (try? store.lastSegmentEndMs(meetingID: meeting.id)) ?? 0
        let duration = max(meeting.durationMs, scanned, stored)
        let endedAt = meeting.endedAt ?? meeting.startedAt.addingTimeInterval(Double(duration) / 1_000)
        do {
            try store.setRecovered(meeting.id, status: .ready, endedAt: endedAt, durationMs: duration, gap: gap)
        } catch {
            logger.error("The meeting could not be marked ready; the audio is kept")
            return .databaseUnwritable
        }
        // `deleted` is recorded only when the removal is confirmed; otherwise the next recovery pass retries.
        guard spool.removeConfirmed(meeting: uuid, keys: keys) else {
            logger.error("The spool could not be removed; it stays and is retried")
            return .ready
        }
        do {
            try store.setAudioState(meeting.id, state: .deleted)
        } catch {
            logger.error("The audio state could not be updated after deleting the spool")
        }
        return .ready
    }
}
