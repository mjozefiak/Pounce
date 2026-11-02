import Foundation
import os

/// One recording, from the first sample to the finished text (spec: `DictationSession`).
///
/// Audio arrives in chunks and is kept in memory only. A voice activity detector cuts speech into segments;
/// every closed segment goes to the speech engine at once, so when the user stops only the last one is
/// left. The model loads in the background while recording, and segments wait for it, so no word is lost.
actor DictationSession {
    enum Event: Equatable, Sendable {
        case level(Float)
        /// The model is not in memory yet and is being loaded; recording already runs.
        case loadingModel
        case modelLoaded
        /// The recording will stop by itself in this many seconds.
        case limitApproaching(secondsLeft: Int)
        case limitReached
        /// The microphone went away (device unplugged, Mac asleep); what was said so far can still be finished.
        case audioLost
    }

    enum Failure: Error, Equatable {
        /// No speech was heard.
        case silence
        /// The model could not be loaded or every segment failed.
        case engine
        case cancelled
        case notStarted
    }

    struct Output: Equatable, Sendable {
        let text: String
        /// Seconds of audio recorded.
        let duration: Double
        let segmentCount: Int
        /// Segments the engine could not transcribe; their words are missing from `text`.
        let failedSegments: Int
    }

    /// A speech segment longer than this is cut, the speech model's window being 15 seconds.
    static let longestSegment = 14 * AudioFormat.sampleRate
    /// Audio kept before the current speech, so the start of a word is never cut.
    private static let preRoll = AudioFormat.sampleRate / 2

    private let audio: any AudioInput
    private let vad: any VoiceActivityDetector
    private let engine: any SpeechEngine
    private let modelFolder: URL
    private let limit: Int
    private let warning: Int
    private let onEvent: @Sendable (Event) -> Void
    private let logger: Logger

    private var store = SampleStore()
    private var speechStart: Int?
    private var segments: [Task<String?, Never>] = []
    private var loadTask: Task<Bool, Never>?
    private var consumeTask: Task<Void, Never>?
    private var started = false
    private var finishing = false
    private var cancelled = false
    private var warned = false
    private var limitSignalled = false

    /// - Parameters:
    ///   - maximumDuration: the recording ends by itself after this long (spec: 20 minutes).
    ///   - warningBefore: how long before the end the countdown starts (spec: from 18 minutes).
    init(
        audio: any AudioInput,
        vad: any VoiceActivityDetector,
        engine: any SpeechEngine,
        modelFolder: URL,
        maximumDuration: Duration = .seconds(20 * 60),
        warningBefore: Duration = .seconds(2 * 60),
        logger: Logger = Logger(subsystem: "app.pounce", category: "dictation"),
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.audio = audio
        self.vad = vad
        self.engine = engine
        self.modelFolder = modelFolder
        self.limit = Self.samples(in: maximumDuration)
        self.warning = max(0, Self.samples(in: maximumDuration) - Self.samples(in: warningBefore))
        self.onEvent = onEvent
        self.logger = logger
    }

    private static func samples(in duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * AudioFormat.sampleRate
            + Int(Double(parts.attoseconds) / 1e18 * Double(AudioFormat.sampleRate))
    }

    /// Starts capturing and, in the background, loading the model.
    func start() async throws {
        guard !started else { return }
        started = true
        let engine = engine
        let folder = modelFolder
        let onEvent = onEvent
        let logger = logger
        loadTask = Task {
            if await engine.isLoaded { return true }
            onEvent(.loadingModel)
            do {
                try await engine.load(modelFolder: folder)
                onEvent(.modelLoaded)
                return true
            } catch {
                logger.error("Speech model failed to load: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        let onLevel = { @Sendable (level: Float) in onEvent(.level(level)) }
        let stream: AsyncStream<[Float]>
        do {
            stream = try await audio.start(onLevel: onLevel)
        } catch {
            loadTask?.cancel()
            throw error
        }
        consumeTask = Task { [weak self] in
            for await chunk in stream {
                await self?.receive(chunk)
            }
            await self?.streamEnded()
        }
    }

    /// Stops recording and returns the text of everything said.
    func finish() async throws -> Output {
        guard started else { throw Failure.notStarted }
        if cancelled { throw Failure.cancelled }
        finishing = true
        await audio.stop()
        await consumeTask?.value
        if let start = speechStart {
            closeSegment(start..<store.count)
            speechStart = nil
        }
        let tasks = segments
        var parts: [String] = []
        var failed = 0
        for task in tasks {
            if let text = await task.value {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            } else {
                failed += 1
            }
        }
        if cancelled { throw Failure.cancelled }
        guard !tasks.isEmpty else { throw Failure.silence }
        guard failed < tasks.count else { throw Failure.engine }
        guard !parts.isEmpty else { throw Failure.silence }
        return Output(
            text: parts.joined(separator: " "),
            duration: Double(store.count) / Double(AudioFormat.sampleRate),
            segmentCount: tasks.count,
            failedSegments: failed)
    }

    /// Drops the recording: nothing is transcribed or kept.
    func cancel() async {
        cancelled = true
        consumeTask?.cancel()
        loadTask?.cancel()
        for task in segments { task.cancel() }
        await audio.stop()
        store = SampleStore()
        segments = []
        speechStart = nil
    }

    // MARK: Audio

    private func receive(_ chunk: [Float]) async {
        guard !cancelled else { return }
        store.append(chunk)
        let total = store.count
        if !warned, warning > 0, total >= warning {
            warned = true
            onEvent(.limitApproaching(secondsLeft: max(0, (limit - total) / AudioFormat.sampleRate)))
        }
        do {
            for event in try await vad.process(chunk) {
                switch event.kind {
                case .speechStart:
                    if speechStart == nil { speechStart = event.sampleIndex }
                case .speechEnd:
                    if let start = speechStart {
                        closeSegment(start..<max(start, event.sampleIndex))
                        speechStart = nil
                    }
                }
            }
        } catch {
            logger.error("Voice activity detection failed: \(String(describing: error), privacy: .public)")
        }
        if let start = speechStart, store.count - start > Self.longestSegment {
            closeSegment(start..<store.count)
            speechStart = store.count
        }
        store.discard(before: (speechStart ?? store.count) - Self.preRoll)
        if total >= limit, !limitSignalled {
            limitSignalled = true
            onEvent(.limitReached)
        }
    }

    private func streamEnded() {
        if !finishing && !cancelled {
            onEvent(.audioLost)
        }
    }

    /// Hands a closed speech segment to the engine; it waits for the model if it is still loading.
    private func closeSegment(_ range: Range<Int>) {
        let samples = store.slice(range)
        guard !samples.isEmpty else { return }
        let engine = engine
        let load = loadTask
        let logger = logger
        segments.append(
            Task {
                guard await load?.value == true else { return nil }
                do {
                    return try await engine.transcribe(samples).text
                } catch {
                    if !Task.isCancelled {
                        logger.error("A segment failed to transcribe: \(String(describing: error), privacy: .public)")
                    }
                    return nil
                }
            })
    }
}
