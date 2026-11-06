import Foundation
import GRDB
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// An evaluation of the meeting pipeline on one real recording. Off unless `LINTEL_MEETING_EVAL_AUDIO` is set.
/// Only a `-c release` build gives comparable numbers (see `scripts/meeting-eval`).
///
///     LINTEL_MEETING_EVAL_AUDIO=meeting.wav LINTEL_MEETING_EVAL_OUT=/tmp/eval \
///     LINTEL_MEETING_EVAL_SPEECH_FOLDER=<Models>/speech/parakeet-ultra swift test -c release --filter MeetingEvalTests
///
/// Optional: `_NAME`, `_ENGINE` (`parakeet-ultra` | `whisper-large-v3-turbo`), `_LANGUAGE` (`pl` | `en`, Whisper
/// only), `_CODE_VERSION`, `_NOTES_MODEL` (a .gguf), `_DIARIZATION_FOLDER`, `_ALLOW_DEBUG`. The WAV must be
/// 16 kHz mono. The transcript goes only into the JSON; the test prints numbers, never text.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LINTEL_MEETING_EVAL_AUDIO"] != nil))
struct MeetingEvalTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func value(_ key: String) -> String? {
        let value = environment["LINTEL_MEETING_EVAL_\(key)"]
        return (value?.isEmpty ?? true) ? nil : value
    }

    private static func ms(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func unloadAndWait(_ runtime: LlamaRuntime) async {
        await runtime.unload()
        for _ in 0..<100 where await runtime.isLoaded { try? await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func evaluatesARealRecording() async throws {
        #if DEBUG
        if Self.value("ALLOW_DEBUG") == nil {
            Issue.record("Debug build: its timings and memory are not comparable. Run with `-c release`.")
            return
        }
        #endif
        let audioURL = URL(filePath: try #require(Self.value("AUDIO")))
        let outDirectory = URL(filePath: try #require(Self.value("OUT")), directoryHint: .isDirectory)
        let name = Self.value("NAME") ?? audioURL.deletingPathExtension().lastPathComponent
        let engineID = Self.value("ENGINE") ?? "parakeet-ultra"
        let language = Self.value("LANGUAGE") ?? "pl"
        let speechFolder = URL(filePath: try #require(Self.value("SPEECH_FOLDER")), directoryHint: .isDirectory)
        let codeVersion = Self.value("CODE_VERSION") ?? "unknown"

        let engine: any SpeechEngine
        switch engineID {
        case "parakeet-ultra": engine = ParakeetEngine()
        case "whisper-large-v3-turbo": engine = WhisperKitEngine(language: { language })
        default:
            Issue.record("Unknown engine \(engineID)")
            return
        }

        let samples = try WAVFile.samples(from: Data(contentsOf: audioURL))
        let audioSeconds = Double(samples.count) / Double(AudioFormat.sampleRate)
        let source = try WAVFileAudioSource(url: audioURL)

        // Store and spool live in a temporary folder that is removed at the end; the audio never exists
        // outside the encrypted spool in it.
        let directory = try TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.url) }
        let plugin = directory.url.appending(path: "meetings")
        let keys = try testKeys()
        let store = try MeetingsStore.open(in: plugin, keys: keys)
        let vadFolder = speechFolder.appending(path: ModelCatalog.sileroVADPath)

        let session = MeetingSession(
            store: store, keys: keys, spool: SpoolStorage(pluginDirectory: plugin), mic: source, system: nil,
            makeVAD: { LazyVAD(modelFolder: vadFolder) }, engine: engine, modelID: engineID,
            modelFolder: speechFolder, lease: SpeechEngineLease(), sleepAssertion: RecordingSleepAssertion(),
            gate: MeetingSessionGate())

        let sampler = FootprintSampler()
        sampler.start()
        let clock = ContinuousClock()
        let began = clock.now
        _ = try await session.start()
        let outcome = await session.finish()
        let processing = clock.now - began
        let asrPeak = await sampler.stop()
        let processingSeconds = Double(processing.components.seconds) + Double(processing.components.attoseconds) / 1e18

        #expect(outcome.result == .ready, "The meeting did not end ready")
        let id = try #require(outcome.meetingID)
        let fetched: [(id: Int64, segment: EvalResult.Segment)] = try store.read { db in
            try Row.fetchAll(
                db,
                sql:
                    "SELECT id, channel, start_ms, end_ms, text FROM meeting_segment WHERE meeting_id = ? ORDER BY start_ms, id",
                arguments: [id]
            ).map {
                (
                    id: $0["id"],
                    segment: EvalResult.Segment(
                        track: $0["channel"], startMs: $0["start_ms"], endMs: $0["end_ms"], text: $0["text"])
                )
            }
        }
        let segmentIDs = fetched.map(\.id)
        var rows = fetched.map(\.segment)
        // `replayedSegments` counts the segments that waited in the spool (backlog or background queue) and were
        // transcribed after the meeting; `unfinishedSegments` are the ones still not transcribed.
        let deferred = outcome.replayedSegments + outcome.unfinishedSegments

        let asr = EvalResult.ASR(
            processingSeconds: processingSeconds, rtf: processingSeconds / audioSeconds, peakFootprintMB: asrPeak,
            deferredSegments: deferred, segments: rows)
        var result = EvalResult(
            recording: name, audioSeconds: audioSeconds,
            config: .init(engine: engineID, language: language, codeVersion: codeVersion), asr: asr)
        print(
            "MEETING-EVAL asr name=\(name) audioSeconds=\(Self.ms(audioSeconds)) seconds=\(Self.ms(processingSeconds))"
                + " rtf=\(String(format: "%.3f", asr.rtf)) peakMB=\(Self.ms(asrPeak)) segments=\(rows.count)"
                + " deferred=\(deferred)")

        if let folder = Self.value("DIARIZATION_FOLDER") {
            let diarizer = FluidDiarizer(modelFolder: URL(filePath: folder, directoryHint: .isDirectory))
            let footprint = FootprintSampler()
            footprint.start()
            let started = clock.now
            let spans = try await diarizer.diarize(EvalArraySource(samples), maximumSamples: samples.count)
            let elapsed = clock.now - started
            await diarizer.release()
            let peak = await footprint.stop()
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let speakers = Set(spans.map(\.cluster)).count
            result.diarization = .init(seconds: seconds, peakFootprintMB: peak, speakers: speakers)
            // The same assignment the app makes after a meeting (`MeetingFinalizer`): labels "Ja", "Inni", "Mówca N".
            let refs = zip(segmentIDs, rows).map { id, row in
                SegmentRef(
                    id: id, channel: AudioChannel(rawValue: row.track) ?? .mic, startMs: row.startMs,
                    endMs: row.endMs)
            }
            let plan = SpeakerAssigner.diarized(segments: refs, spans: [.mic: spans])
            for (index, id) in segmentIDs.enumerated() {
                if let speaker = plan.assignments[id], plan.speakers.indices.contains(speaker) {
                    rows[index].speaker = plan.speakers[speaker].label
                }
            }
            result.asr.segments = rows
            print(
                "MEETING-EVAL diarization seconds=\(Self.ms(seconds)) peakMB=\(Self.ms(peak)) speakers=\(speakers)")
        }

        if let model = Self.value("NOTES_MODEL") {
            let modelURL = URL(filePath: model)
            var configuration = NotesPipeline.Configuration()
            configuration.chunkTokens = MeetingsSettings.defaultNotesChunkTokens
            configuration.reduceInputTokens = MeetingsSettings.defaultNotesReduceInputTokens
            let runtime = LlamaRuntime(contextLength: NotesModel.contextLength)
            let notesModel = NotesModel(
                lease: LLMLease(), runtime: runtime, modelURL: modelURL, keepWarm: { .seconds(1) })
            let traceEvents = Mutex<[NotesTraceEvent]>([])
            let pipeline = NotesPipeline(
                model: notesModel, configuration: configuration,
                trace: { event in traceEvents.withLock { $0.append(event) } })
            let utterances = rows.map { NotesUtterance(startMs: $0.startMs, speaker: $0.speaker ?? "?", text: $0.text) }
            let footprint = FootprintSampler()
            footprint.start()
            let started = clock.now
            let notes: NotesResult
            do {
                notes = try await pipeline.run(utterances: utterances)
            } catch {
                await Self.unloadAndWait(runtime)
                throw error
            }
            // The keep-warm timer would unload the model after the test (and the process) ended: ggml aborts
            // at exit while a Metal resource set is alive. Unload now and wait until it is really gone.
            await Self.unloadAndWait(runtime)
            let elapsed = clock.now - started
            let peak = await footprint.stop()
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            result.notes = .init(
                model: modelURL.lastPathComponent, seconds: seconds, peakFootprintMB: peak,
                status: notes.status.rawValue, chunkCount: notes.chunkCount, verifiedPoints: notes.verifiedPointCount,
                dropped: notes.droppedCount, failedChunks: notes.failedChunks.count, reduceFailed: notes.reduceFailed,
                markdown: notes.markdown ?? "")
            let events = traceEvents.withLock { $0 }
            let balance = NotesTrace.balance(of: events)
            let traceURL = try EvalResultWriter.write(NotesTraceFile(recording: name, events: events), to: outDirectory)
            print(
                "MEETING-EVAL notes-trace events=\(events.count) verified=\(balance.verified)"
                    + " rendered=\(balance.rendered) notRendered=\(balance.notRendered)"
                    + " unexplained=\(balance.unexplained)")
            print("MEETING-EVAL wrote \(traceURL.path)")
            print(
                "MEETING-EVAL notes seconds=\(Self.ms(seconds)) peakMB=\(Self.ms(peak)) status=\(notes.status.rawValue)"
                    + " chunks=\(notes.chunkCount) points=\(notes.verifiedPointCount) dropped=\(notes.droppedCount)")
        }

        let written = try EvalResultWriter.write(result, to: outDirectory)
        print("MEETING-EVAL wrote \(written.path)")
    }
}

/// An in-memory source of Float chunks for the diarizer (the evaluation has no spool for it).
private final class EvalArraySource: AudioSampleSource {
    private let samples: [Float]
    private let position = Mutex(0)
    let sampleRate = 16_000
    var endState: AudioEndState? { position.withLock { $0 } >= samples.count ? .complete : nil }

    init(_ samples: [Float]) { self.samples = samples }

    func nextChunk() throws -> [Float]? {
        let range = position.withLock { position -> Range<Int> in
            let start = position
            position = min(samples.count, start + 32_000)
            return start..<position
        }
        return range.isEmpty ? nil : Array(samples[range])
    }
}
