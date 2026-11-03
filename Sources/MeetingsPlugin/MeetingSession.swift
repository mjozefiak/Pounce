import Foundation
import PounceSpeech
import Synchronization
import os

/// One recording (spec: `MeetingSession`): two tracks (`mic`, `system`), each with its own voice activity
/// detector, cut into segments of at most 15 s that go to the speech engine through `SpeechEngineLease`
/// (priority `.background`) and into the library as they are transcribed. Every sample also goes to an
/// encrypted spool per track. The loop VAD to engine is a copy of `DictationSession`'s, not shared.
///
/// - The tracks must arrive aligned on one timeline (`SystemAudioSource` pads the track that starts later,
///   `TimelineAlignment`), so a track's sample index is its time since the common start.
/// - A segment the lease hands back as `.spool` (the background queue holds a minute of audio) or that cannot
///   be transcribed because the model is unavailable stays in the spool and is transcribed after the meeting
///   (the replay), while the state is `processing`.
/// - Microphone segments wait until the system track is known up to their end, then `EchoSuppressor` decides
///   whether they are echoes of what the speakers played.
/// - Transcript text and audio never reach a log: only counts and durations.
actor MeetingSession {
    typealias Event = MeetingSessionEvent
    typealias Outcome = MeetingSessionOutcome

    /// A speech segment is cut at this length (the model's window is 15 s); never longer.
    static let longestSegment = 15 * AudioFormat.sampleRate
    /// Audio kept before the current speech, so the start of a word is never cut.
    private static let preRoll = AudioFormat.sampleRate / 2
    /// A microphone segment is judged once the system track is known this long past its end (voice activity
    /// detection reports speech late).
    private static let echoSlackMs = 1_500

    nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let store: MeetingsStore
    private let keys: MeetingKeys
    private let spoolStorage: SpoolStorage
    private let engine: any SpeechEngine
    private let modelID: String
    private let modelFolder: URL
    private let lease: SpeechEngineLease
    private let keepWarm: @Sendable () -> Duration
    private let sleepAssertion: any SleepAssertion
    private let gate: MeetingSessionGate
    private let limits: MeetingSessionLimits
    private let freeSpace: SpoolWriter.FreeSpaceProvider
    private let echo: EchoSuppressor
    private let now: @Sendable () -> Date
    private let beforeReady: (@Sendable (Int64, UUID) async -> Void)?
    private let logger: Logger
    private let inputs: [(channel: AudioChannel, audio: any AudioInput)]
    private let makeVAD: @Sendable () -> any VoiceActivityDetector
    let meetingUUID: UUID

    private(set) var state = MeetingSessionState.idle
    private(set) var meetingID: Int64?

    private var tracks: [AudioChannel: TrackState] = [:]
    private var loadTask: Task<SpeechLease?, Never>?
    private var leaseHandle: SpeechLease?
    private var started = false
    private var finishTask: Task<Outcome, Never>?
    private var nextSegmentID = 0
    private var held: [TrackSegment] = []
    private var systemSegments: [TrackSegment] = []
    private var savedCount = 0
    private var failedSegments = 0
    private var replayedSegments = 0
    private var echoesDropped = 0
    private var databaseFailed = false
    private var lastSecond = 0
    private var limitSignalled = false
    private var lastDiskCheck = 0
    private var replayUnavailable = false

    private let limitSamples: Int
    private let warningSamples: Int

    /// - Parameters:
    ///   - mic: the microphone; `system` the system audio (`nil` records the microphone only).
    ///   - makeVAD: called once per track.
    ///   - beforeReady: runs while the state is `processing`, after the transcript is complete and before the
    ///     meeting becomes `ready` and its spool is deleted (diarization plugs in here).
    init(
        store: MeetingsStore, keys: MeetingKeys, spool: SpoolStorage, mic: any AudioInput,
        system: (any AudioInput)?, makeVAD: @escaping @Sendable () -> any VoiceActivityDetector,
        engine: any SpeechEngine, modelID: String, modelFolder: URL, lease: SpeechEngineLease = .shared,
        keepWarm: @escaping @Sendable () -> Duration = { .seconds(600) }, sleepAssertion: any SleepAssertion,
        gate: MeetingSessionGate, limits: MeetingSessionLimits = MeetingSessionLimits(),
        freeSpace: @escaping SpoolWriter.FreeSpaceProvider = { try SpoolStorage.systemFreeSpace(at: $0) },
        echo: EchoSuppressor = EchoSuppressor(), uuid: UUID = UUID(), now: @escaping @Sendable () -> Date = { Date() },
        beforeReady: (@Sendable (Int64, UUID) async -> Void)? = nil,
        logger: Logger = Logger(subsystem: "app.pounce", category: "meetings")
    ) {
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        self.store = store
        self.keys = keys
        spoolStorage = spool
        self.engine = engine
        self.modelID = modelID
        self.modelFolder = modelFolder
        self.lease = lease
        self.keepWarm = keepWarm
        self.sleepAssertion = sleepAssertion
        self.gate = gate
        self.limits = limits
        self.freeSpace = freeSpace
        self.echo = echo
        meetingUUID = uuid
        self.now = now
        self.beforeReady = beforeReady
        self.logger = logger
        self.makeVAD = makeVAD
        var list: [(AudioChannel, any AudioInput)] = [(.mic, mic)]
        if let system { list.append((.system, system)) }
        inputs = list
        limitSamples = MeetingSessionLimits.samples(in: limits.maximumDuration)
        warningSamples = max(
            0,
            MeetingSessionLimits.samples(in: limits.maximumDuration)
                - MeetingSessionLimits.samples(in: limits.warningBefore))
    }

    // MARK: Start

    /// Creates the library entry and the spool, takes the speech model in the background and starts the
    /// audio. Throws (leaving nothing behind) when another session is active, the disk has too little space or
    /// no audio source starts.
    @discardableResult
    func start() async throws -> Int64 {
        guard !started else { throw MeetingSessionError.alreadyStarted }
        guard gate.tryAcquire() else { throw MeetingSessionError.anotherSessionActive }
        started = true
        do {
            let writers = try createSpool()
            let id = try insertMeeting(cleaningUp: writers)
            meetingID = id
            sleepAssertion.hold(reason: "Pounce is recording a meeting")
            startModelLoad()
            try await startAudio(writers: writers)
        } catch {
            await abortStart()
            throw error
        }
        setState(.recording)
        return meetingID ?? 0
    }

    private func createSpool() throws -> [AudioChannel: SpoolWriter] {
        if inputs.count == 2 {
            let pair = try SpoolWriter.createPair(
                in: spoolStorage, meeting: meetingUUID, keys: keys, minimumFreeBytes: limits.startFreeBytes,
                freeSpace: freeSpace)
            return [.mic: pair.mic, .system: pair.system]
        }
        let mic = try SpoolWriter.create(
            in: spoolStorage, meeting: meetingUUID, track: .mic, keys: keys, minimumFreeBytes: limits.startFreeBytes,
            freeSpace: freeSpace)
        return [.mic: mic]
    }

    private func insertMeeting(cleaningUp writers: [AudioChannel: SpoolWriter]) throws -> Int64 {
        do {
            return try store.insertMeeting(
                uuid: SpoolStorage.name(of: meetingUUID), startedAt: now(), speechModelID: modelID)
        } catch {
            for writer in writers.values { try? writer.abandon() }
            _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
            throw MeetingSessionError.database
        }
    }

    private func startModelLoad() {
        let lease = lease
        let engine = engine
        let id = modelID
        let folder = modelFolder
        let keepWarm = keepWarm
        let continuation = continuation
        let logger = logger
        loadTask = Task {
            let loading = LoadFlag()
            do {
                let handle = try await lease.acquire(
                    modelID: id, folder: folder, engine: engine, priority: .background, keepWarm: keepWarm,
                    onLoading: {
                        loading.set()
                        continuation.yield(.loadingModel)
                    })
                if loading.value { continuation.yield(.modelLoaded) }
                return handle
            } catch {
                let busy = (error as? ModelLeaseError) == .busy
                logger.error("Meeting speech model unavailable (busy: \(busy, privacy: .public))")
                if !Task.isCancelled { continuation.yield(.modelUnavailable(busy: busy)) }
                return nil
            }
        }
    }

    private func startAudio(writers: [AudioChannel: SpoolWriter]) async throws {
        for input in inputs {
            let channel = input.channel
            let continuation = continuation
            let onLevel = { @Sendable (level: Float) in _ = continuation.yield(.level(channel, level)) }
            do {
                let stream = try await input.audio.start(onLevel: onLevel)
                let track = TrackState(channel: channel, audio: input.audio, vad: makeVAD())
                track.spool = writers[channel]
                tracks[channel] = track
                track.consume = Task { [weak self] in
                    for await chunk in stream { await self?.receive(channel, chunk) }
                    await self?.streamEnded(channel)
                }
            } catch {
                logger.error("Audio track \(channel.rawValue, privacy: .public) did not start")
                continuation.yield(.trackUnavailable(channel))
                if let writer = writers[channel] { try? writer.abandon() }
            }
        }
        if tracks.isEmpty { throw MeetingSessionError.noAudioInput }
    }

    /// Undoes a start that failed: nothing stays in the library or in the spool.
    private func abortStart() async {
        for track in tracks.values {
            track.consume?.cancel()
            await track.audio.stop()
        }
        tracks = [:]
        let load = loadTask
        loadTask = nil
        load?.cancel()
        await load?.value?.release()
        if let id = meetingID { try? store.deleteMeetings([id]) }
        meetingID = nil
        _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
        sleepAssertion.release()
        gate.release()
        started = false
        continuation.finish()
    }

    // MARK: Audio

    private func receive(_ channel: AudioChannel, _ chunk: [Float]) async {
        guard let track = tracks[channel], !chunk.isEmpty else { return }
        track.store.append(chunk)
        track.received = track.store.count
        if let writer = track.spool, !track.spoolFailed {
            do {
                try writer.append(chunk.map(Self.int16))
            } catch {
                track.spoolFailed = true
                logger.error("Spool of \(channel.rawValue, privacy: .public) failed")
                continuation.yield(.spoolFailed(channel))
            }
        }
        do {
            for event in try await track.vad.process(chunk) {
                switch event.kind {
                case .speechStart:
                    if track.speechStart == nil { track.speechStart = event.sampleIndex }
                case .speechEnd:
                    if let start = track.speechStart {
                        closeSegment(channel, start..<max(start, event.sampleIndex))
                        track.speechStart = nil
                    }
                }
            }
        } catch {
            logger.error("Voice activity detection failed on \(channel.rawValue, privacy: .public)")
        }
        // Never a segment longer than the model's window.
        while let start = track.speechStart, track.store.count - start > Self.longestSegment {
            closeSegment(channel, start..<start + Self.longestSegment)
            track.speechStart = start + Self.longestSegment
        }
        track.store.discard(before: (track.speechStart ?? track.store.count) - Self.preRoll)
        progress()
        commitReady(force: false)
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * 32_767)
    }

    private func streamEnded(_ channel: AudioChannel) {
        guard let track = tracks[channel] else { return }
        track.alive = false
        guard state == .recording, finishTask == nil else { return }
        logger.notice("Audio track \(channel.rawValue, privacy: .public) ended")
        continuation.yield(.trackLost(channel))
        if !tracks.values.contains(where: \.alive) { requestFinish() }
        commitReady(force: false)
    }

    /// Elapsed time, the 3 h limit and the free-space check, driven by the audio that arrives.
    private func progress() {
        let samples = tracks.values.map(\.received).max() ?? 0
        let second = samples / AudioFormat.sampleRate
        if second > lastSecond {
            lastSecond = second
            continuation.yield(.elapsed(seconds: second))
            if warningSamples > 0, samples >= warningSamples {
                continuation.yield(
                    .limitApproaching(secondsLeft: max(0, (limitSamples - samples) / AudioFormat.sampleRate)))
            }
        }
        if samples >= limitSamples, !limitSignalled {
            limitSignalled = true
            continuation.yield(.limitReached)
            requestFinish()
        }
        let interval = max(1, MeetingSessionLimits.samples(in: limits.diskCheckEvery))
        if finishTask == nil, samples - lastDiskCheck >= interval {
            lastDiskCheck = samples
            if let available = try? freeSpace(spoolStorage.root), available < limits.stopFreeBytes {
                logger.error("Low disk space while recording")
                continuation.yield(.lowDisk)
                requestFinish()
            }
        }
    }

    // MARK: Segments

    private enum SegmentOutcome: Sendable {
        case text(String)
        case deferred
        case failed
    }

    private func closeSegment(_ channel: AudioChannel, _ range: Range<Int>) {
        guard let track = tracks[channel] else { return }
        let samples = track.store.slice(range)
        guard !samples.isEmpty else { return }
        let id = nextSegmentID
        nextSegmentID += 1
        track.inflight[id] = Self.milliseconds(range.lowerBound)
        let load = loadTask
        let logger = logger
        // No waiting for the previous segment here: the lease queue (FIFO) keeps the order, and when it holds a
        // minute of audio it answers `.spool`, which only works if segments reach it without a queue of our own.
        track.tasks[id] = Task { [weak self] in
            let handle = await load?.value
            let outcome: SegmentOutcome
            if let handle {
                do {
                    switch try await handle.transcribe(samples) {
                    case .transcript(let segment): outcome = .text(segment.text)
                    case .spool: outcome = .deferred
                    }
                } catch {
                    logger.error("A segment failed to transcribe")
                    outcome = .failed
                }
            } else {
                outcome = .deferred
            }
            await self?.resolved(channel, id, range, outcome)
        }
    }

    private func resolved(_ channel: AudioChannel, _ id: Int, _ range: Range<Int>, _ outcome: SegmentOutcome) {
        guard let track = tracks[channel] else { return }
        track.inflight[id] = nil
        track.tasks[id] = nil
        switch outcome {
        case .text(let text): accept(channel, range, text)
        case .deferred: track.deferred.append(range)
        case .failed: failedSegments += 1
        }
        commitReady(force: false)
    }

    private func accept(_ channel: AudioChannel, _ range: Range<Int>, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let start = Int64(Self.milliseconds(range.lowerBound))
        let end = Int64(Self.milliseconds(range.upperBound))
        switch channel {
        case .system:
            let segment = TrackSegment(track: .system, startMs: start, endMs: end, text: trimmed)
            systemSegments.append(segment)
            save(segment)
        case .mic:
            held.append(TrackSegment(track: .microphone, startMs: start, endMs: end, text: trimmed))
        }
    }

    private static func milliseconds(_ sample: Int) -> Int { sample * 1_000 / AudioFormat.sampleRate }

    /// Until when a track's text is final: the start of its earliest unfinished speech or deferred segment, the
    /// end of what it received while it lives, and for ever once it is dead and finished.
    private func horizonMs(_ channel: AudioChannel) -> Int {
        guard let track = tracks[channel] else { return .max }
        var horizon = track.alive ? Self.milliseconds(track.received) : .max
        if let start = track.speechStart { horizon = min(horizon, Self.milliseconds(start)) }
        for start in track.inflight.values { horizon = min(horizon, start) }
        for range in track.deferred { horizon = min(horizon, Self.milliseconds(range.lowerBound)) }
        return horizon
    }

    /// Writes the microphone segments the system track can no longer contradict. `force` writes all of them.
    private func commitReady(force: Bool) {
        let horizon = horizonMs(.system)
        while let first = held.first, force || horizon == .max || horizon >= Int(first.endMs) + Self.echoSlackMs {
            held.removeFirst()
            systemSegments.removeAll { $0.endMs < first.startMs - 30_000 }
            if echo.suppressing(systemSegments + [first]).contains(first) {
                save(first)
            } else {
                echoesDropped += 1
            }
        }
    }

    private func save(_ segment: TrackSegment) {
        guard let id = meetingID else { return }
        let channel: AudioChannel = segment.track == .system ? .system : .mic
        do {
            try store.insertSegment(
                meetingID: id, channel: channel, startMs: Int(segment.startMs), endMs: Int(segment.endMs),
                text: segment.text)
            savedCount += 1
            continuation.yield(.segmentSaved(channel, total: savedCount))
        } catch {
            logger.error("A segment could not be saved")
            if !databaseFailed {
                databaseFailed = true
                continuation.yield(.databaseWriteFailed)
            }
        }
    }

    // MARK: Finish

    private func requestFinish() {
        guard finishTask == nil else { return }
        Task { [weak self] in _ = await self?.finish() }
    }

    /// Stops the audio, transcribes what is left (including what waited in the spool) and ends the meeting.
    /// Safe to call again, and from the limit, the disk check or the plugin being switched off: the first call
    /// does the work, the others get its result.
    func finish() async -> Outcome {
        if let task = finishTask { return await task.value }
        guard state == .recording else { return Outcome(result: .notStarted) }
        let task = Task { await self.runFinish() }
        finishTask = task
        return await task.value
    }

    private func runFinish() async -> Outcome {
        setState(.finishing)
        if let id = meetingID { try? store.setStatus(id, status: .processing) }
        for track in tracks.values { await track.audio.stop() }
        for track in tracks.values { await track.consume?.value }
        for (channel, track) in tracks {
            if let start = track.speechStart {
                closeSegment(channel, start..<track.store.count)
                track.speechStart = nil
            }
            track.alive = false
        }
        for track in tracks.values {
            while let task = track.tasks.values.first { await task.value }
        }
        commitReady(force: false)
        for track in tracks.values { closeSpool(track) }
        sleepAssertion.release()

        setState(.processing)
        leaseHandle = await loadTask?.value
        await replayDeferred()
        commitReady(force: true)
        await releaseLease()

        let outcome = await conclude()
        gate.release()
        continuation.yield(.finished(outcome))
        continuation.finish()
        return outcome
    }

    private func closeSpool(_ track: TrackState) {
        guard let writer = track.spool else { return }
        do {
            try writer.close()
        } catch {
            if !track.spoolFailed { continuation.yield(.spoolFailed(track.channel)) }
            track.spoolFailed = true
        }
    }

    private func releaseLease() async {
        loadTask = nil
        let handle = leaseHandle
        leaseHandle = nil
        await handle?.release()
    }

    private var deferredCount: Int { tracks.values.reduce(0) { $0 + $1.deferred.count } }

    // MARK: Replay

    /// Transcribes, from the spool, the segments the background queue refused or the missing model left
    /// waiting.
    private func replayDeferred() async {
        guard deferredCount > 0 else { return }
        if leaseHandle == nil {
            // The model was not available during the meeting: try once more now.
            do {
                leaseHandle = try await lease.acquire(
                    modelID: modelID, folder: modelFolder, engine: engine, priority: .background, keepWarm: keepWarm)
            } catch {
                replayUnavailable = true
                logger.error("Speech model unavailable for the deferred segments")
                return
            }
        }
        guard let handle = leaseHandle else { return }
        for channel in [AudioChannel.mic, .system] {
            guard let track = tracks[channel], !track.deferred.isEmpty else { continue }
            await replay(track, handle: handle)
        }
    }

    private func replay(_ track: TrackState, handle: SpeechLease) async {
        let ranges = track.deferred.sorted { $0.lowerBound < $1.lowerBound }
        guard !track.spoolFailed,
            let spoolTrack = SpoolTrack(rawValue: track.channel.rawValue),
            let reader = try? SpoolReader(
                file: spoolStorage.file(for: meetingUUID, track: spoolTrack), meeting: meetingUUID, track: spoolTrack,
                keys: keys)
        else {
            failReplay(track, ranges[...])
            return
        }
        var index = 0
        var position = 0
        var window: [Float] = []
        do {
            while index < ranges.count, let chunk = try reader.nextChunk() {
                window += chunk
                position += chunk.count
                while index < ranges.count, ranges[index].upperBound <= position {
                    await replayRange(
                        track, ranges[index], window: window, windowStart: position - window.count, handle)
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
            logger.error("The spool of \(track.channel.rawValue, privacy: .public) could not be read")
            failReplay(track, ranges[index...])
            return
        }
        // The stream ended before the last ranges did (a damaged tail): transcribe what exists.
        while index < ranges.count {
            await replayRange(track, ranges[index], window: window, windowStart: position - window.count, handle)
            index += 1
        }
    }

    private func failReplay(_ track: TrackState, _ remaining: ArraySlice<Range<Int>>) {
        failedSegments += remaining.count
        track.deferred.removeAll { remaining.contains($0) }
        commitReady(force: false)
    }

    private func replayRange(
        _ track: TrackState, _ range: Range<Int>, window: [Float], windowStart: Int, _ handle: SpeechLease
    ) async {
        let from = max(0, range.lowerBound - windowStart)
        let to = min(window.count, range.upperBound - windowStart)
        guard from < to else {
            failReplay(track, [range][...])
            return
        }
        await replayOne(track, range, Array(window[from..<to]), handle: handle)
    }

    private func replayOne(_ track: TrackState, _ range: Range<Int>, _ samples: [Float], handle: SpeechLease) async {
        continuation.yield(.replaying(remaining: deferredCount))
        let outcome: SegmentOutcome
        do {
            switch try await handle.transcribe(samples) {
            case .transcript(let segment): outcome = .text(segment.text)
            case .spool: outcome = .failed
            }
        } catch {
            outcome = .failed
        }
        track.deferred.removeAll { $0 == range }
        switch outcome {
        case .text(let text):
            replayedSegments += 1
            accept(track.channel, range, text)
        case .deferred, .failed: failedSegments += 1
        }
        commitReady(force: false)
    }

    // MARK: Conclusion

    private func conclude() async -> Outcome {
        let samples = tracks.values.map(\.received).max() ?? 0
        let durationMs = Self.milliseconds(samples)
        var outcome = Outcome(
            result: .ready, meetingID: meetingID, segmentCount: savedCount, durationMs: durationMs,
            failedSegments: failedSegments, replayedSegments: replayedSegments, echoesDropped: echoesDropped)
        let silent = savedCount == 0 && deferredCount == 0 && failedSegments == 0 && echoesDropped == 0
        let shortest = Int(limits.discardBelow.components.seconds) * 1_000
        if silent, durationMs < shortest {
            if let id = meetingID { try? store.deleteMeetings([id]) }
            _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
            outcome.result = .discarded
            outcome.meetingID = nil
            meetingID = nil
            logger.notice("Meeting discarded: nothing heard")
            continuation.yield(.nothingHeard)
            setState(.idle)
            return outcome
        }
        guard let id = meetingID else {
            outcome.result = .failed
            setState(.failed)
            return outcome
        }
        let endedAt = now()
        if replayUnavailable && deferredCount > 0 {
            try? store.setStatus(id, status: .incomplete, endedAt: endedAt, durationMs: durationMs)
            outcome.result = .incomplete
            setState(.incomplete)
        } else if savedCount == 0 && failedSegments > 0 {
            try? store.setStatus(id, status: .failed, endedAt: endedAt, durationMs: durationMs)
            outcome.result = .failed
            setState(.failed)
        } else {
            await beforeReady?(id, meetingUUID)
            try? store.setStatus(id, status: .ready, endedAt: endedAt, durationMs: durationMs)
            _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
            try? store.setAudioState(id, state: .deleted)
            setState(.ready)
        }
        logger.notice(
            "Meeting finished: \(self.savedCount, privacy: .public) segments, \(durationMs / 1_000, privacy: .public) s"
        )
        return outcome
    }

    private func setState(_ new: MeetingSessionState) {
        state = new
        continuation.yield(.stateChanged(new))
    }
}

/// One audio track of a session; only the session's actor touches it.
private final class TrackState {
    let channel: AudioChannel
    let audio: any AudioInput
    let vad: any VoiceActivityDetector
    var spool: SpoolWriter?
    var spoolFailed = false
    var store = SampleStore()
    var speechStart: Int?
    var received = 0
    var alive = true
    var inflight: [Int: Int] = [:]
    var deferred: [Range<Int>] = []
    var tasks: [Int: Task<Void, Never>] = [:]
    var consume: Task<Void, Never>?

    init(channel: AudioChannel, audio: any AudioInput, vad: any VoiceActivityDetector) {
        self.channel = channel
        self.audio = audio
        self.vad = vad
    }
}

private final class LoadFlag: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func set() { flag.withLock { $0 = true } }
}
