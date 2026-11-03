import Foundation
import PounceSpeech
import Synchronization

/// What happened to the tap while recording, for the HUD.
enum SystemAudioEvent: Equatable, Sendable {
    /// The default output changed and a new tap runs; the gap was filled with silence.
    case recreated
    /// The tap could not be recreated; the track continues as silence until the next chance.
    case recreateFailed(SystemAudioError)
    /// The tap's sample rate or channel count changed (a Bluetooth headset switching profile, say); the
    /// conversion was reconfigured and the timeline continues.
    case formatChanged
    /// Implausible time stamps (a huge gap or a clock far behind) were absorbed: at most a few seconds of
    /// silence were inserted and the timeline was re-based on the new stamps.
    case timelineResynced
    /// The default-output listener could not be installed; device changes will go unnoticed.
    case outputChangesNotObserved(SystemAudioError)
}

/// The timeline logic of one system-audio track, without Core Audio: converts buffers to 16 kHz mono and
/// keeps the sample count in step with host time by inserting silence where buffers are missing (a tap being
/// recreated, a stalled device) and trimming overlaps. Sample `n` of the output is at
/// `anchor + n / 16000` seconds.
struct SystemAudioPipeline: Sendable {
    static let sampleRate = AudioFormat.sampleRate
    /// The most silence one buffer may add (5 s). A larger jump is a bad stamp, not a real stall: it is
    /// absorbed by re-basing the timeline instead of allocating without bound.
    static let maxGapSamples = 5 * AudioFormat.sampleRate
    /// A stamp this far behind the output (1 s) is stale, not jitter.
    static let maxBackstepSamples = AudioFormat.sampleRate

    let converter: HostTimeConverter
    /// Host time of output sample 0; set from the first buffer unless given.
    private(set) var anchorHostTime: UInt64?
    private(set) var emittedSamples = 0
    /// How often the sample rate or channel count changed mid-stream.
    private(set) var formatChanges = 0
    /// How often implausible stamps forced a re-base of the timeline.
    private(set) var resyncs = 0
    private var resampler: MonoResampler?
    private var resamplerKey: String?
    /// Samples subtracted from stamp-derived positions after a re-base.
    private var shiftSamples = 0
    private var lastHostTime: UInt64?
    /// Differences below this many samples are jitter, not a gap (about 20 ms).
    private let toleranceSamples = AudioFormat.sampleRate / 50

    init(converter: HostTimeConverter, anchorHostTime: UInt64? = nil) {
        self.converter = converter
        self.anchorHostTime = anchorHostTime
    }

    /// The output for `buffer`: leading silence for a gap, then the converted samples.
    mutating func ingest(_ buffer: TapBuffer) -> [Float] {
        guard buffer.channels > 0, buffer.sampleRate > 0, buffer.sampleRate.isFinite else { return [] }
        let key = "\(buffer.channels)@\(buffer.sampleRate)"
        if key != resamplerKey {
            if resamplerKey != nil { formatChanges += 1 }
            resampler = MonoResampler(
                inputRate: buffer.sampleRate, outputRate: Double(Self.sampleRate), channels: buffer.channels)
            resamplerKey = key
        }
        let anchor = anchorHostTime ?? buffer.hostTime
        anchorHostTime = anchor
        var converted = resampler?.process(interleaved: buffer.samples) ?? []
        guard !converted.isEmpty else { return [] }

        var output: [Float] = []
        if let last = lastHostTime, buffer.hostTime <= last {
            // A stamp that does not advance is stale (host time is monotonic): follow the previous buffer.
        } else {
            lastHostTime = buffer.hostTime
            let start = sampleIndex(forHostTime: buffer.hostTime, anchor: anchor) - shiftSamples
            if start > emittedSamples + toleranceSamples {
                var gap = start - emittedSamples
                if gap > Self.maxGapSamples {
                    shiftSamples += gap - Self.maxGapSamples
                    resyncs += 1
                    gap = Self.maxGapSamples
                }
                output = [Float](repeating: 0, count: gap)
            } else if start < emittedSamples - Self.maxBackstepSamples {
                shiftSamples += start - emittedSamples
                resyncs += 1
            } else if start < emittedSamples - toleranceSamples {
                // A buffer from the past (the clock stepped back): drop the part that was already covered.
                converted.removeFirst(min(converted.count, emittedSamples - start))
            }
        }
        output.append(contentsOf: converted)
        emittedSamples += output.count
        return output
    }

    /// Silence up to `hostTime`, for the end of the recording or a tap that stays down.
    mutating func padding(upTo hostTime: UInt64) -> [Float] {
        guard let anchor = anchorHostTime else { return [] }
        let target = sampleIndex(forHostTime: hostTime, anchor: anchor) - shiftSamples
        guard target > emittedSamples else { return [] }
        let silence = [Float](repeating: 0, count: target - emittedSamples)
        emittedSamples = target
        return silence
    }

    /// Forgets the conversion state of a tap that was replaced; the timeline continues.
    mutating func tapReplaced() {
        resampler = nil
        resamplerKey = nil
    }

    private func sampleIndex(forHostTime hostTime: UInt64, anchor: UInt64) -> Int {
        TimelineAlignment(originHostTime: anchor, converter: converter)
            .sampleOffset(forHostTime: hostTime, sampleRate: Self.sampleRate)
    }
}

/// System audio as 16 kHz mono `Float32` chunks: a Core Audio process tap of everything except Pounce
/// itself. Recreates the tap when the default output changes and fills the gap with silence. Audio exists
/// only in memory and is never logged.
///
/// The stream is one continuous timeline starting at `anchorHostTime`, so it lines up with the microphone
/// track through `TimelineAlignment`.
final class SystemAudioSource: AudioInput, @unchecked Sendable {
    private struct State {
        var pipeline: SystemAudioPipeline
        var continuation: AsyncStream<[Float]>.Continuation?
        var onLevel: (@Sendable (Float) -> Void)?
        var session: (any ProcessTapSession)?
        var observation: (any OutputChangeObservation)?
        /// Bumped on every tap; buffers of an older tap are ignored.
        var generation = 0
        var recreation: Task<Void, Never>?
        var running = false
    }

    private let backend: any ProcessTapBackend
    private let clock: any HostClock
    private let enabled: Bool
    private let excludeOwnProcess: Bool
    private let configuredAnchor: UInt64?
    private let onEvent: @Sendable (SystemAudioEvent) -> Void
    private let restartDelay: Duration
    private let sleeper: @Sendable (Duration) async -> Void
    private let maxRecreateAttempts: Int
    private let state: Mutex<State>

    /// - Parameters:
    ///   - enabled: the `plugins.meetings.systemAudio` flag; `start` throws `.disabled` when false.
    ///   - anchorHostTime: the shared start of the recording; `nil` starts the timeline at the first buffer.
    init(
        backend: any ProcessTapBackend, clock: any HostClock = SystemHostClock(),
        converter: HostTimeConverter = .system, enabled: Bool = true, excludeOwnProcess: Bool = true,
        anchorHostTime: UInt64? = nil, restartDelay: Duration = .milliseconds(300), maxRecreateAttempts: Int = 3,
        sleeper: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onEvent: @escaping @Sendable (SystemAudioEvent) -> Void = { _ in }
    ) {
        self.backend = backend
        self.clock = clock
        self.enabled = enabled
        self.excludeOwnProcess = excludeOwnProcess
        configuredAnchor = anchorHostTime
        self.restartDelay = restartDelay
        self.sleeper = sleeper
        self.maxRecreateAttempts = max(1, maxRecreateAttempts)
        self.onEvent = onEvent
        state = Mutex(State(pipeline: SystemAudioPipeline(converter: converter, anchorHostTime: anchorHostTime)))
    }

    deinit {
        shutdown(finishWith: nil)
    }

    /// Host time of output sample 0, once known.
    var anchorHostTime: UInt64? { state.withLock { $0.pipeline.anchorHostTime } }

    func start(onLevel: @escaping @Sendable (Float) -> Void) async throws -> AsyncStream<[Float]> {
        guard enabled else { throw SystemAudioError.disabled }
        let (stream, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        let alreadyRunning = state.withLock { state -> Bool in
            if state.running { return true }
            state.running = true
            state.continuation = continuation
            state.onLevel = onLevel
            // A fresh timeline for every start, so a source that was stopped begins from zero again. Without
            // an explicit anchor it starts when capture is requested, so audio that arrives late is
            // preceded by silence instead of shifting the track.
            state.pipeline = SystemAudioPipeline(
                converter: state.pipeline.converter, anchorHostTime: configuredAnchor ?? clock.now())
            state.recreation = nil
            return false
        }
        guard !alreadyRunning else {
            continuation.finish()
            return stream
        }
        let session: any ProcessTapSession
        do {
            session = try openTap()
        } catch {
            shutdown(finishWith: nil)
            throw error
        }
        // The session is stored before the output observation exists, so a device change can never find the
        // tap missing and open a second one that this assignment would then overwrite.
        let (kept, previous) = state.withLock { state -> (Bool, (any ProcessTapSession)?) in
            guard state.running else { return (false, nil) }
            let previous = state.session
            state.session = session
            return (true, previous)
        }
        previous?.stop()
        guard kept else {
            // stop() ran while the tap was opening.
            session.stop()
            continuation.finish()
            return stream
        }
        do throws(SystemAudioError) {
            let observation = try backend.observeOutputDeviceChanges { [weak self] in self?.outputDeviceChanged() }
            let stored = state.withLock { state -> Bool in
                guard state.running else { return false }
                state.observation = observation
                return true
            }
            if !stored { observation.cancel() }
        } catch {
            onEvent(.outputChangesNotObserved(error))
        }
        return stream
    }

    func stop() async {
        shutdown(finishWith: clock.now())
    }

    // MARK: Tap

    private func openTap() throws(SystemAudioError) -> any ProcessTapSession {
        let generation = state.withLock { state -> Int in
            state.generation += 1
            return state.generation
        }
        return try backend.startTap(excludingOwnProcess: excludeOwnProcess) { [weak self] buffer in
            self?.receive(buffer, generation: generation)
        }
    }

    private func receive(_ buffer: TapBuffer, generation: Int) {
        var buffer = buffer
        if !buffer.hostTimeValid || buffer.hostTime == 0 {
            // No usable stamp from the IO proc: place the buffer by the clock instead.
            buffer.hostTime = clock.now()
        }
        let (chunk, continuation, onLevel, events) = state.withLock {
            state -> ([Float], AsyncStream<[Float]>.Continuation?, (@Sendable (Float) -> Void)?, [SystemAudioEvent]) in
            guard state.running, state.generation == generation else { return ([], nil, nil, []) }
            let formatChanges = state.pipeline.formatChanges
            let resyncs = state.pipeline.resyncs
            let chunk = state.pipeline.ingest(buffer)
            var events: [SystemAudioEvent] = []
            if state.pipeline.formatChanges != formatChanges { events.append(.formatChanged) }
            if state.pipeline.resyncs != resyncs { events.append(.timelineResynced) }
            return (chunk, state.continuation, state.onLevel, events)
        }
        emit(chunk, to: continuation, onLevel: onLevel)
        for event in events { onEvent(event) }
    }

    private func emit(
        _ chunk: [Float], to continuation: AsyncStream<[Float]>.Continuation?, onLevel: (@Sendable (Float) -> Void)?
    ) {
        guard !chunk.isEmpty, let continuation else { return }
        onLevel?(MicrophoneCapture.level(of: chunk))
        continuation.yield(chunk)
    }

    // MARK: Output device change

    private func outputDeviceChanged() {
        state.withLock { state in
            guard state.running else { return }
            let previous = state.recreation
            state.recreation = Task { [weak self] in
                await previous?.value
                await self?.recreateTap()
            }
        }
    }

    private func recreateTap() async {
        // Retire the old tap first: its buffers carry the old format and device.
        let retired = state.withLock { state -> (any ProcessTapSession)? in
            guard state.running else { return nil }
            state.generation += 1
            defer {
                state.session = nil
                state.pipeline.tapReplaced()
            }
            return state.session
        }
        retired?.stop()
        var failure: SystemAudioError = .tapUnavailable(0)
        for _ in 0..<maxRecreateAttempts {
            // The new device needs a moment before a tap on it works.
            await sleeper(restartDelay)
            guard state.withLock({ $0.running }) else { return }
            do {
                let session = try openTap()
                let (keep, previous) = state.withLock { state -> (Bool, (any ProcessTapSession)?) in
                    guard state.running else { return (false, nil) }
                    // Never overwrite a live session: it would leak.
                    let previous = state.session
                    state.session = session
                    return (true, previous)
                }
                previous?.stop()
                if keep {
                    onEvent(.recreated)
                } else {
                    session.stop()
                }
                return
            } catch {
                failure = error
            }
        }
        // Keep the timeline moving as silence; the next change event tries again.
        let (silence, continuation, onLevel) = state.withLock {
            state -> ([Float], AsyncStream<[Float]>.Continuation?, (@Sendable (Float) -> Void)?) in
            (state.pipeline.padding(upTo: clock.now()), state.continuation, state.onLevel)
        }
        emit(silence, to: continuation, onLevel: onLevel)
        onEvent(.recreateFailed(failure))
    }

    // MARK: Teardown

    /// Stops the tap and the observation and ends the stream, optionally padding the timeline with silence up
    /// to `hostTime` so the track ends where the recording ends.
    private func shutdown(finishWith hostTime: UInt64?) {
        let (session, observation, continuation, recreation, silence, onLevel) = state.withLock {
            state -> (
                (any ProcessTapSession)?, (any OutputChangeObservation)?, AsyncStream<[Float]>.Continuation?,
                Task<Void, Never>?, [Float], (@Sendable (Float) -> Void)?
            ) in
            let silence = hostTime.map { state.pipeline.padding(upTo: $0) } ?? []
            let result = (
                state.session, state.observation, state.continuation, state.recreation, silence, state.onLevel
            )
            state.running = false
            state.generation += 1
            state.session = nil
            state.observation = nil
            state.continuation = nil
            state.onLevel = nil
            state.recreation = nil
            return result
        }
        recreation?.cancel()
        observation?.cancel()
        session?.stop()
        emit(silence, to: continuation, onLevel: onLevel)
        continuation?.finish()
    }
}
