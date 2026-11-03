import Foundation
import PounceSpeech
import Synchronization
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
        /// The transcript as the speech engine heard it, without formatting (equal to `text` in raw mode).
        let rawText: String
        /// How many chunks went to the formatter and how many of them came back raw.
        let formatting: FormattingSummary
    }

    struct FormattingSummary: Equatable, Sendable {
        var chunks = 0
        var fellBack = 0
        var firstReason: FallbackReason?
        var isPartial: Bool { fellBack > 0 }
    }

    /// A speech segment longer than this is cut, the speech model's window being 15 seconds.
    static let longestSegment = 14 * AudioFormat.sampleRate
    /// Audio kept before the current speech, so the start of a word is never cut.
    private static let preRoll = AudioFormat.sampleRate / 2

    private let audio: any AudioInput
    private let vad: any VoiceActivityDetector
    private let engine: any SpeechEngine
    private let lease: SpeechEngineLease
    private let modelID: String
    private let keepWarm: @Sendable () -> Duration
    private let formatter: (any TextFormatter)?
    private let modelFolder: URL
    private let limit: Int
    private let warning: Int
    private let onEvent: @Sendable (Event) -> Void
    private let logger: Logger

    private var store = SampleStore()
    private var speechStart: Int?
    private var segments: [Task<String?, Never>] = []
    private var segmenter = Segmenter()
    private var lastSegmentEnd: Int?
    private var assembling: Task<Void, Never>?
    private var chunks: [(chunk: Segmenter.Chunk, result: Task<FormatResult, Never>)] = []
    private var lastChunkText: String?
    private var loadTask: Task<SpeechLease?, Never>?
    /// The formatter's own warm-up; left running on cancel, a warm model is wanted for the next dictation.
    private var prepareTask: Task<Void, Never>?
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
        formatter: (any TextFormatter)? = nil,
        modelFolder: URL,
        lease: SpeechEngineLease = SpeechEngineLease(),
        modelID: String = "dictation",
        keepWarm: @escaping @Sendable () -> Duration = { .seconds(600) },
        maximumDuration: Duration = .seconds(20 * 60),
        warningBefore: Duration = .seconds(2 * 60),
        logger: Logger = Logger(subsystem: "app.pounce", category: "dictation"),
        onEvent: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        self.audio = audio
        self.vad = vad
        self.engine = engine
        self.lease = lease
        self.modelID = modelID
        self.keepWarm = keepWarm
        self.formatter = formatter
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
        let lease = lease
        let modelID = modelID
        let keepWarm = keepWarm
        let folder = modelFolder
        let onEvent = onEvent
        let logger = logger
        loadTask = Task {
            let loading = Mutex(false)
            do {
                let handle = try await lease.acquire(
                    modelID: modelID, folder: folder, engine: engine, priority: .interactive, keepWarm: keepWarm,
                    onLoading: {
                        loading.withLock { $0 = true }
                        onEvent(.loadingModel)
                    })
                if loading.withLock({ $0 }) { onEvent(.modelLoaded) }
                return handle
            } catch {
                logger.error("Speech model failed to load: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        if let formatter {
            // A formatter with a model of its own loads it while the user speaks.
            prepareTask = Task { await formatter.prepare() }
        }
        let onLevel = { @Sendable (level: Float) in onEvent(.level(level)) }
        let stream: AsyncStream<[Float]>
        do {
            stream = try await audio.start(onLevel: onLevel)
        } catch {
            loadTask?.cancel()
            await releaseLease()
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
        do {
            let output = try await produce()
            await releaseLease()
            return output
        } catch {
            await releaseLease()
            throw error
        }
    }

    /// Gives the engine lease back (once), whenever it was or is still being acquired. The engine then stays
    /// loaded for the keep-warm time.
    private func releaseLease() async {
        guard let load = loadTask else { return }
        loadTask = nil
        await load.value?.release()
    }

    private func produce() async throws -> Output {
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
        // Every segment is transcribed: the engine is not needed any more while the text is formatted.
        await releaseLease()
        if cancelled { throw Failure.cancelled }
        guard !tasks.isEmpty else { throw Failure.silence }
        guard failed < tasks.count else { throw Failure.engine }
        guard !parts.isEmpty else { throw Failure.silence }
        let raw = parts.joined(separator: " ")
        var text = raw
        var summary = FormattingSummary()
        if formatter != nil {
            await assembling?.value
            for chunk in segmenter.flush() { startFormatting(chunk) }
            let assembled = await assembleChunks()
            if cancelled { throw Failure.cancelled }
            if !assembled.text.isEmpty {
                text = assembled.text
                summary = assembled.summary
            }
        }
        return Output(
            text: text,
            duration: Double(store.count) / Double(AudioFormat.sampleRate),
            segmentCount: tasks.count,
            failedSegments: failed,
            rawText: raw,
            formatting: summary)
    }

    /// The formatted chunks in the order they were said, whatever order the server answered in.
    private func assembleChunks() async -> (text: String, summary: FormattingSummary) {
        var summary = FormattingSummary()
        var text = ""
        var paragraphBreak = false
        for (chunk, task) in chunks {
            let result = await task.value
            summary.chunks += 1
            if case .fellBack(let reason) = result.outcome {
                summary.fellBack += 1
                summary.firstReason = summary.firstReason ?? reason
            }
            let piece = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if !text.isEmpty { text += paragraphBreak ? "\n\n" : " " }
            text += piece
            paragraphBreak = chunk.endsParagraph
        }
        return (text, summary)
    }

    /// Drops the recording: nothing is transcribed or kept.
    func cancel() async {
        cancelled = true
        consumeTask?.cancel()
        loadTask?.cancel()
        for task in segments { task.cancel() }
        assembling?.cancel()
        for entry in chunks { entry.result.cancel() }
        await audio.stop()
        store = SampleStore()
        segments = []
        chunks = []
        speechStart = nil
        await releaseLease()
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
        let load = loadTask
        let logger = logger
        // The engine takes one segment at a time (the lease queue); asking in the order the segments were said
        // keeps the order in which they are transcribed the same as the order in which they were spoken.
        let previous = segments.last
        let task = Task<String?, Never> {
            guard let handle = await load?.value else { return nil }
            _ = await previous?.value
            do {
                guard case .transcript(let segment) = try await handle.transcribe(samples) else { return nil }
                return segment.text
            } catch {
                if !Task.isCancelled {
                    logger.error("A segment failed to transcribe: \(String(describing: error), privacy: .public)")
                }
                return nil
            }
        }
        segments.append(task)

        let pause = lastSegmentEnd.map { Double(max(0, range.lowerBound - $0)) / Double(AudioFormat.sampleRate) } ?? 0
        lastSegmentEnd = range.upperBound
        if formatter != nil {
            // One chain, so segments reach the segmenter in the order they were said even though they are
            // transcribed in parallel.
            let previous = assembling
            assembling = Task { [weak self] in
                await previous?.value
                guard let text = await task.value else { return }
                await self?.segmentTranscribed(text, pauseBefore: pause)
            }
        }
    }

    private func segmentTranscribed(_ text: String, pauseBefore: Double) {
        guard !cancelled else { return }
        for chunk in segmenter.add(text, pauseBefore: pauseBefore) { startFormatting(chunk) }
    }

    /// Sends one chunk to the formatter now, with the end of the previous chunk as context.
    private func startFormatting(_ chunk: Segmenter.Chunk) {
        guard let formatter else { return }
        let context = lastChunkText.map { String($0.suffix(300)) }
        lastChunkText = chunk.text
        let result = Task<FormatResult, Never> {
            do {
                return try await formatter.format(chunk: chunk.text, previousContext: context)
            } catch {
                // Cancelled: the session is being dropped, the value is never used.
                return FormatResult(text: chunk.text, outcome: .fellBack(.unreachable))
            }
        }
        chunks.append((chunk, result))
    }
}
