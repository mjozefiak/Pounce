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
/// - A segment that the track's own backlog (a minute of audio) refuses, that the lease hands back as `.spool`,
///   that fails to transcribe or that cannot be transcribed because the model is unavailable stays in the
///   spool and is transcribed after the meeting (the replay), while the state is `processing`.
/// - Audio is never deleted unless the whole transcript was transcribed and written (spec Q7): a segment that
///   still fails after the replay, or a failed database write, ends the meeting `incomplete` with the spool
///   kept; `failed` only when nothing is left that a later run could finish.
/// - Microphone segments wait until the system track is known up to their end (at most `micHoldLimit`), then
///   `EchoSuppressor` decides whether they are echoes of what the speakers played.
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
    /// System text older than this before the earliest possible microphone segment cannot echo into it.
    private static let echoWindowMs = 30_000
    private static let maxHeld = 50
    private static let maxSystemSegments = 500

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
    /// A `finish()` arrived while `start()` was still running (tests wait for it).
    var isFinishPending: Bool { pendingFinish }

    /// `meeting.source_bundle_id`: the app of the accepted suggestion, `nil` otherwise.
    private let sourceBundleID: String?
    private var tracks: [AudioChannel: TrackState] = [:]
    private var loadTask: Task<SpeechLease?, Never>?
    private var leaseHandle: SpeechLease?
    private var started = false
    private var finishTask: Task<Outcome, Never>?
    private var nextSegmentID = 0
    /// Microphone text waiting for the system track, sorted by start.
    private var held: [TrackSegment] = []
    private var systemSegments: [TrackSegment] = []
    private var pruneFloor = 0
    private var savedCount = 0
    private var failedSegments = 0
    private var replayedSegments = 0
    private var echoesDropped = 0
    private var echoesUnchecked = 0
    private var echoWarned = false
    private var writeFailures = 0
    private var databaseFailed = false
    /// Segments whose audio is intact in the spool but whose text is not in the library.
    private var keptSegments = 0
    private var lastSecond = 0
    private var limitSignalled = false
    private var lastDiskCheck = 0
    private var lastDiskCheckAt = Date.distantPast
    private var startedAt = Date.distantPast
    private var replayUnavailable = false
    private var pendingFinish = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var heartbeatTask: Task<Void, Never>?
    private let sleep: @Sendable (Duration) async throws -> Void

    private let limitSamples: Int
    private let warningSamples: Int

    /// - Parameters:
    ///   - mic: the microphone; `system` the system audio (`nil` records the microphone only).
    ///   - makeVAD: called once per track.
    ///   - now, sleep: the wall clock and the wait of the heartbeat that enforces the limits when no audio
    ///     arrives; tests drive both.
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
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        beforeReady: (@Sendable (Int64, UUID) async -> Void)? = nil,
        sourceBundleID: String? = nil,
        logger: Logger = Logger(subsystem: "app.pounce", category: "meetings")
    ) {
        self.sourceBundleID = sourceBundleID
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
        self.sleep = sleep
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
    /// no audio source starts; a failed start can be retried on the same session and its events keep flowing.
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
            wakeStartWaiters()
            throw error
        }
        setState(.recording)
        startHeartbeat()
        // A finish requested while starting, or the only track having ended meanwhile, takes effect now.
        if pendingFinish || !tracks.values.contains(where: \.alive) { _ = beginFinish() }
        wakeStartWaiters()
        return meetingID ?? 0
    }

    private func wakeStartWaiters() {
        let waiters = startWaiters
        startWaiters = []
        for waiter in waiters { waiter.resume() }
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
                uuid: SpoolStorage.name(of: meetingUUID), startedAt: now(), speechModelID: modelID,
                sourceBundleID: sourceBundleID)
        } catch {
            for writer in writers.values { try? writer.abandon() }
            _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
            throw MeetingSessionError.database
        }
    }

    /// Takes the lease, telling the HUD when the model has to be loaded.
    private func acquireLease() async throws -> SpeechLease {
        let loading = LoadFlag()
        let continuation = continuation
        let handle = try await lease.acquire(
            modelID: modelID, folder: modelFolder, engine: engine, priority: .background, keepWarm: keepWarm,
            onLoading: {
                loading.set()
                continuation.yield(.loadingModel)
            })
        if loading.value { continuation.yield(.modelLoaded) }
        return handle
    }

    private func startModelLoad() {
        let continuation = continuation
        let logger = logger
        loadTask = Task { [weak self] in
            do {
                guard let self else { return nil }
                return try await self.acquireLease()
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
                track.lastAudioAt = now()
                tracks[channel] = track
                track.consume = Task { [weak self] in
                    for await chunk in stream { await self?.receive(track, chunk) }
                    await self?.streamEnded(track)
                }
            } catch {
                logger.error("Audio track \(channel.rawValue, privacy: .public) did not start")
                continuation.yield(.trackUnavailable(channel))
                if let writer = writers[channel] { try? writer.abandon() }
            }
        }
        if tracks.isEmpty { throw MeetingSessionError.noAudioInput }
        startedAt = now()
        lastDiskCheckAt = startedAt
    }

    /// Undoes a start that failed: nothing stays in the library or in the spool. The event stream stays open
    /// so that a retried start reports on it; it ends with the session's `finish`.
    private func abortStart() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for track in tracks.values {
            track.consume?.cancel()
            await track.audio.stop()
        }
        tracks = [:]
        let load = loadTask
        loadTask = nil
        load?.cancel()
        await load?.value?.release()
        if let id = meetingID {
            do {
                try store.deleteMeetings([id])
            } catch {
                logger.error("An aborted meeting could not be removed from the library")
            }
        }
        meetingID = nil
        _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
        sleepAssertion.release()
        gate.release()
        started = false
        pendingFinish = false
        nextSegmentID = 0
    }

    // MARK: Heartbeat

    /// The limits and the stalled-stream check are normally driven by arriving audio; this wall-clock beat makes
    /// them work when the audio stops arriving without the stream ending.
    private func startHeartbeat() {
        let interval = limits.heartbeat
        let sleep = sleep
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() async {
        guard state == .recording, finishTask == nil else { return }
        let current = now()
        if current.timeIntervalSince(startedAt) >= MeetingSessionLimits.seconds(limits.maximumDuration),
            !limitSignalled
        {
            limitSignalled = true
            continuation.yield(.limitReached)
            requestFinish()
            return
        }
        let stall = MeetingSessionLimits.seconds(limits.stallTimeout)
        for track in tracks.values where track.alive && current.timeIntervalSince(track.lastAudioAt) >= stall {
            logger.error("Audio track \(track.channel.rawValue, privacy: .public) stalled")
            track.consume?.cancel()
            await track.audio.stop()
            lose(track)
        }
        if finishTask == nil,
            current.timeIntervalSince(lastDiskCheckAt) >= MeetingSessionLimits.seconds(limits.diskCheckEvery)
        {
            lastDiskCheckAt = current
            checkDisk()
        }
    }

    // MARK: Audio

    private func receive(_ track: TrackState, _ chunk: [Float]) async {
        let channel = track.channel
        guard tracks[channel] === track, track.alive, !chunk.isEmpty else { return }
        track.store.append(chunk)
        track.received = track.store.count
        track.lastAudioAt = now()
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
                        closeSegment(track, start..<max(start, event.sampleIndex))
                        track.speechStart = nil
                    }
                }
            }
        } catch {
            logger.error("Voice activity detection failed on \(channel.rawValue, privacy: .public)")
        }
        // Never a segment longer than the model's window.
        while let start = track.speechStart, track.store.count - start > Self.longestSegment {
            closeSegment(track, start..<start + Self.longestSegment)
            track.speechStart = start + Self.longestSegment
        }
        track.store.discard(before: (track.speechStart ?? track.store.count) - Self.preRoll)
        progress()
        commitReady(force: false)
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * 32_767)
    }

    private func streamEnded(_ track: TrackState) {
        guard tracks[track.channel] === track, track.alive else { return }
        guard finishTask == nil, state == .recording || state == .idle else {
            track.alive = false
            return
        }
        logger.notice("Audio track \(track.channel.rawValue, privacy: .public) ended")
        lose(track)
    }

    /// A track is gone while recording (or while starting): its open speech is closed, the other track carries
    /// on, and when none is left the meeting ends.
    private func lose(_ track: TrackState) {
        track.alive = false
        continuation.yield(.trackLost(track.channel))
        if let start = track.speechStart {
            closeSegment(track, start..<track.store.count)
            track.speechStart = nil
        }
        // While starting, `start()` finishes the session once it knows no track is left.
        if state == .recording, !tracks.values.contains(where: \.alive) { requestFinish() }
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
            checkDisk()
        }
    }

    private func checkDisk() {
        do {
            if try freeSpace(spoolStorage.root) < limits.stopFreeBytes {
                logger.error("Low disk space while recording")
                continuation.yield(.lowDisk)
                requestFinish()
            }
        } catch {
            // The check could not be made; the spool's own write errors still stop a full disk.
            logger.error("The free space could not be read")
        }
    }

    // MARK: Segments

    private enum SegmentOutcome: Sendable {
        case text(String)
        case deferred
        case failed
    }

    fileprivate struct Job {
        let id: Int
        let range: Range<Int>
        let samples: [Float]
    }

    /// Hands a closed segment to the track's worker. A track has one worker, so segments reach the lease in the
    /// order they were spoken; when the worker's backlog already holds a minute of audio the segment waits in
    /// the spool instead (the replay transcribes it after the meeting), which keeps memory bounded.
    private func closeSegment(_ track: TrackState, _ range: Range<Int>) {
        let samples = track.store.slice(range)
        guard !samples.isEmpty else { return }
        if track.backlogSamples > 0, track.backlogSamples + samples.count > SpeechEngineLease.backgroundLimit {
            track.deferred.append(range)
            return
        }
        let id = nextSegmentID
        nextSegmentID += 1
        track.backlogSamples += samples.count
        track.inflight[id] = Self.milliseconds(range.lowerBound)
        track.queue.append(Job(id: id, range: range, samples: samples))
        guard track.worker == nil else { return }
        let load = loadTask
        let logger = logger
        track.worker = Task { [weak self] in
            while let self, let job = await self.nextJob(track) {
                let outcome = await Self.transcribe(job.samples, load: load, logger: logger)
                await self.resolved(track, job, outcome)
            }
        }
    }

    private func nextJob(_ track: TrackState) -> Job? {
        guard !track.queue.isEmpty else {
            track.worker = nil
            return nil
        }
        return track.queue.removeFirst()
    }

    private static func transcribe(
        _ samples: [Float], load: Task<SpeechLease?, Never>?, logger: Logger
    ) async -> SegmentOutcome {
        guard let handle = await load?.value else { return .deferred }
        do {
            switch try await handle.transcribe(samples) {
            case .transcript(let segment): return .text(segment.text)
            case .spool: return .deferred
            }
        } catch {
            logger.error("A segment failed to transcribe")
            return .failed
        }
    }

    private func resolved(_ track: TrackState, _ job: Job, _ outcome: SegmentOutcome) {
        track.inflight[job.id] = nil
        track.backlogSamples -= job.samples.count
        switch outcome {
        case .text(let text): accept(track.channel, job.range, text)
        // A failed segment gets one more try from the spool after the meeting, like a deferred one.
        case .deferred, .failed: track.deferred.append(job.range)
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
            let segment = TrackSegment(track: .microphone, startMs: start, endMs: end, text: trimmed)
            let index = held.firstIndex { $0.startMs > start } ?? held.endIndex
            held.insert(segment, at: index)
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

    /// Writes the microphone segments the system track can no longer contradict, or that waited too long.
    /// `force` writes all of them (the end of the meeting); the echo check still uses every system segment
    /// there is, and a segment written without the system track known up to its end is counted and flagged.
    private func commitReady(force: Bool) {
        let horizon = horizonMs(.system)
        let mediaNow = Self.milliseconds(tracks.values.map(\.received).max() ?? 0)
        let holdLimit = Int(MeetingSessionLimits.seconds(limits.micHoldLimit) * 1_000)
        pruneSystemSegments()
        while let first = held.first {
            let complete = horizon == .max || horizon >= Int(first.endMs) + Self.echoSlackMs
            let aged = mediaNow - Int(first.endMs) >= holdLimit || held.count > Self.maxHeld
            guard force || complete || aged else { break }
            held.removeFirst()
            if !complete {
                echoesUnchecked += 1
                if !echoWarned {
                    echoWarned = true
                    continuation.yield(.echoMayRemain)
                }
            }
            if echo.isEcho(first, of: systemSegments) {
                echoesDropped += 1
            } else {
                save(first)
            }
        }
        pruneSystemSegments()
    }

    /// Drops system text no future microphone segment can overlap. The bound only moves forward: it follows
    /// the earliest microphone work still open (or waiting), never the segment last written.
    private func pruneSystemSegments() {
        var earliest = horizonMs(.mic)
        if let first = held.first { earliest = min(earliest, Int(first.startMs)) }
        if earliest == .max {
            systemSegments.removeAll()
            return
        }
        pruneFloor = max(pruneFloor, earliest - Self.echoWindowMs)
        systemSegments.removeAll { Int($0.endMs) < pruneFloor }
        if systemSegments.count > Self.maxSystemSegments {
            systemSegments.removeFirst(systemSegments.count - Self.maxSystemSegments)
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
            writeFailures += 1
            // The audio is still in the spool, so a later run can write the text again.
            if let track = tracks[channel], !track.spoolFailed { keptSegments += 1 }
            if !databaseFailed {
                databaseFailed = true
                continuation.yield(.databaseWriteFailed)
            }
        }
    }

    // MARK: Finish

    private func requestFinish() {
        if state == .recording {
            _ = beginFinish()
        } else if started, state == .idle {
            pendingFinish = true
        }
    }

    private func beginFinish() -> Task<Outcome, Never> {
        if let task = finishTask { return task }
        let task = Task { await self.runFinish() }
        finishTask = task
        return task
    }

    /// Stops the audio, transcribes what is left (including what waited in the spool) and ends the meeting.
    /// Safe to call again, and from the limit, the disk check or the plugin being switched off: the first call
    /// does the work, the others get its result. Called while `start()` is still running, it waits for the start
    /// and then finishes.
    func finish() async -> Outcome {
        if let task = finishTask { return await task.value }
        if started, state == .idle {
            pendingFinish = true
            await withCheckedContinuation { startWaiters.append($0) }
            if let task = finishTask { return await task.value }
            return Outcome(result: .notStarted)
        }
        guard state == .recording else { return Outcome(result: .notStarted) }
        return await beginFinish().value
    }

    private func runFinish() async -> Outcome {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        setState(.finishing)
        if let id = meetingID {
            do {
                try store.setStatus(id, status: .processing)
            } catch {
                logger.error("The meeting could not be marked as processing")
            }
        }
        for track in tracks.values { await track.audio.stop() }
        for track in tracks.values { await track.consume?.value }
        for track in tracks.values {
            if let start = track.speechStart {
                closeSegment(track, start..<track.store.count)
                track.speechStart = nil
            }
            track.alive = false
        }
        for track in tracks.values {
            while let worker = track.worker { await worker.value }
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

    /// Transcribes, from the spool, the segments the backlog, the background queue or the missing model left
    /// waiting, and retries the ones that failed.
    private func replayDeferred() async {
        guard deferredCount > 0 else { return }
        if leaseHandle == nil {
            // The model was not available during the meeting: try once more now.
            do {
                leaseHandle = try await acquireLease()
            } catch {
                replayUnavailable = true
                logger.error("Speech model unavailable for the deferred segments")
                // What cannot be replayed later either (its spool is damaged) is lost; the rest stays deferred.
                for track in tracks.values where track.spoolFailed && !track.deferred.isEmpty {
                    failReplay(track, track.deferred[...])
                }
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

    /// Audio that cannot be read back from the spool: lost for good, and counted as failed.
    private func failReplay(_ track: TrackState, _ remaining: ArraySlice<Range<Int>>) {
        failedSegments += remaining.count
        let lost = Array(remaining)
        track.deferred.removeAll { lost.contains($0) }
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
        case .deferred, .failed:
            // Readable but not transcribable: stays in the spool for a later run.
            failedSegments += 1
            keptSegments += 1
        }
        commitReady(force: false)
    }

    // MARK: Conclusion

    private func conclude() async -> Outcome {
        let samples = tracks.values.map(\.received).max() ?? 0
        let durationMs = Self.milliseconds(samples)
        var outcome = Outcome(
            result: .ready, meetingID: meetingID, segmentCount: savedCount, durationMs: durationMs,
            failedSegments: failedSegments, replayedSegments: replayedSegments, echoesDropped: echoesDropped,
            writeFailures: writeFailures, unfinishedSegments: deferredCount + keptSegments,
            echoesUnchecked: echoesUnchecked)
        let silent =
            savedCount == 0 && deferredCount == 0 && failedSegments == 0 && echoesDropped == 0 && writeFailures == 0
        let shortest = Int(limits.discardBelow.components.seconds) * 1_000
        if silent, durationMs < shortest, discardMeeting() {
            outcome.result = .discarded
            outcome.meetingID = nil
            setState(.idle)
            return outcome
        }
        guard let id = meetingID else {
            outcome.result = .failed
            setState(.failed)
            return outcome
        }
        let endedAt = now()
        let unresolved = deferredCount + failedSegments + writeFailures
        if unresolved == 0 {
            await beforeReady?(id, meetingUUID)
            if Task.isCancelled {
                // The hook was cut short (e.g. diarization on quit): the audio stays for a later run.
                outcome.result = settleUnfinished(id, endedAt: endedAt, durationMs: durationMs, recoverable: true)
            } else if markReady(id, endedAt: endedAt, durationMs: durationMs) {
                setState(.ready)
            } else {
                // The meeting could not be marked ready, so the audio stays: it is not finished.
                outcome.result = settleUnfinished(id, endedAt: endedAt, durationMs: durationMs, recoverable: true)
            }
        } else {
            let recoverable = deferredCount + keptSegments > 0
            outcome.result = settleUnfinished(id, endedAt: endedAt, durationMs: durationMs, recoverable: recoverable)
        }
        logger.notice(
            "Meeting finished: \(self.savedCount, privacy: .public) segments, \(durationMs / 1_000, privacy: .public) s"
        )
        return outcome
    }

    /// Removes a silent short meeting. False (and nothing announced) when the row could not be removed.
    private func discardMeeting() -> Bool {
        if let id = meetingID {
            do {
                try store.deleteMeetings([id])
            } catch {
                logger.error("A silent meeting could not be removed from the library")
                return false
            }
        }
        _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
        meetingID = nil
        logger.notice("Meeting discarded: nothing heard")
        continuation.yield(.nothingHeard)
        return true
    }

    /// The audio is deleted only after the status really is `ready` (spec Q7).
    private func markReady(_ id: Int64, endedAt: Date, durationMs: Int) -> Bool {
        do {
            try store.setStatus(id, status: .ready, endedAt: endedAt, durationMs: durationMs)
        } catch {
            logger.error("The meeting could not be marked ready; the audio is kept")
            return false
        }
        _ = spoolStorage.removeSpools(forMeetings: [SpoolStorage.name(of: meetingUUID)])
        do {
            try store.setAudioState(id, state: .deleted)
        } catch {
            logger.error("The audio state could not be updated after deleting the spool")
        }
        return true
    }

    /// `incomplete` when a later run could still finish the meeting (something is saved, or audio waits in a
    /// readable spool); `failed` when nothing is left to build on, or the status cannot be written. The spool
    /// is kept either way.
    private func settleUnfinished(_ id: Int64, endedAt: Date, durationMs: Int, recoverable: Bool) -> Outcome.Result {
        let incomplete = savedCount > 0 || recoverable
        do {
            try store.setStatus(
                id, status: incomplete ? .incomplete : .failed, endedAt: endedAt, durationMs: durationMs)
        } catch {
            logger.error("The final status of the meeting could not be written")
            setState(.failed)
            return .failed
        }
        setState(incomplete ? .incomplete : .failed)
        return incomplete ? .incomplete : .failed
    }

    private func setState(_ new: MeetingSessionState) {
        state = new
        continuation.yield(.stateChanged(new))
    }
}

/// One audio track of a session; only the session's actor touches it.
private final class TrackState: @unchecked Sendable {
    let channel: AudioChannel
    let audio: any AudioInput
    let vad: any VoiceActivityDetector
    var spool: SpoolWriter?
    var spoolFailed = false
    var store = SampleStore()
    var speechStart: Int?
    var received = 0
    var alive = true
    var lastAudioAt = Date.distantPast
    var inflight: [Int: Int] = [:]
    var deferred: [Range<Int>] = []
    var queue: [MeetingSession.Job] = []
    var backlogSamples = 0
    var worker: Task<Void, Never>?
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
