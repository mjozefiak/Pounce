import Foundation
import PounceSpeech
import Synchronization

/// What happened to the tap while recording, for the HUD.
enum SystemAudioEvent: Equatable, Sendable {
    /// The default output changed and a new tap runs; the gap was filled with silence.
    case recreated
    /// The tap could not be recreated; the track continues as silence until the next chance.
    case recreateFailed(SystemAudioError)
}

/// The timeline logic of one system-audio track, without Core Audio: converts buffers to 16 kHz mono and
/// keeps the sample count in step with host time by inserting silence where buffers are missing (a tap being
/// recreated, a stalled device) and trimming overlaps. Sample `n` of the output is at
/// `anchor + n / 16000` seconds.
struct SystemAudioPipeline: Sendable {
    static let sampleRate = AudioFormat.sampleRate

    let converter: HostTimeConverter
    /// Host time of output sample 0; set from the first buffer unless given.
    private(set) var anchorHostTime: UInt64?
    private(set) var emittedSamples = 0
    private var resampler: MonoResampler?
    private var resamplerKey: String?
    /// Differences below this many samples are jitter, not a gap (about 20 ms).
    private let toleranceSamples = AudioFormat.sampleRate / 50

    init(converter: HostTimeConverter, anchorHostTime: UInt64? = nil) {
        self.converter = converter
        self.anchorHostTime = anchorHostTime
    }

    /// The output for `buffer`: leading silence for a gap, then the converted samples.
    mutating func ingest(_ buffer: TapBuffer) -> [Float] {
        guard buffer.channels > 0, buffer.sampleRate > 0 else { return [] }
        let key = "\(buffer.channels)@\(buffer.sampleRate)"
        if key != resamplerKey {
            resampler = MonoResampler(
                inputRate: buffer.sampleRate, outputRate: Double(Self.sampleRate), channels: buffer.channels)
            resamplerKey = key
        }
        let anchor = anchorHostTime ?? buffer.hostTime
        anchorHostTime = anchor
        var converted = resampler?.process(interleaved: buffer.samples) ?? []
        guard !converted.isEmpty else { return [] }

        let start = sampleIndex(forHostTime: buffer.hostTime, anchor: anchor)
        var output: [Float] = []
        if start > emittedSamples + toleranceSamples {
            output = [Float](repeating: 0, count: start - emittedSamples)
        } else if start < emittedSamples - toleranceSamples {
            // A buffer from the past (the clock stepped back): drop the part that was already covered.
            converted.removeFirst(min(converted.count, emittedSamples - start))
        }
        output.append(contentsOf: converted)
        emittedSamples += output.count
        return output
    }

    /// Silence up to `hostTime`, for the end of the recording or a tap that stays down.
    mutating func padding(upTo hostTime: UInt64) -> [Float] {
        guard let anchor = anchorHostTime else { return [] }
        let target = sampleIndex(forHostTime: hostTime, anchor: anchor)
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
            // Without an explicit anchor, the timeline starts when capture is requested, so audio that
            // arrives late is preceded by silence instead of shifting the track.
            if state.pipeline.anchorHostTime == nil {
                state.pipeline = SystemAudioPipeline(converter: state.pipeline.converter, anchorHostTime: clock.now())
            }
            return false
        }
        guard !alreadyRunning else {
            continuation.finish()
            return stream
        }
        do {
            let session = try openTap()
            let observation = backend.observeOutputDeviceChanges { [weak self] in self?.outputDeviceChanged() }
            state.withLock { state in
                state.session = session
                state.observation = observation
            }
        } catch {
            shutdown(finishWith: nil)
            throw error
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
        let (chunk, continuation, onLevel) = state.withLock {
            state -> ([Float], AsyncStream<[Float]>.Continuation?, (@Sendable (Float) -> Void)?) in
            guard state.running, state.generation == generation else { return ([], nil, nil) }
            return (state.pipeline.ingest(buffer), state.continuation, state.onLevel)
        }
        emit(chunk, to: continuation, onLevel: onLevel)
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
                let keep = state.withLock { state -> Bool in
                    guard state.running else { return false }
                    state.session = session
                    return true
                }
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
