import Foundation
import OSLog
import PounceSpeech

/// What the finalizer did for one meeting. Carries no text and no audio, so it can be logged and shown.
enum DiarizationOutcome: Equatable, Sendable {
    /// Speakers were recognised (`speaker_mode = diarized`).
    case diarized(speakers: Int)
    /// The recognition did not run or did not finish; the transcript got "Ja / Inni" by track
    /// (`speaker_mode = channels`; the meeting window shows the banner for that mode) or, when only one side
    /// spoke, no labels. `reason` says why.
    case fallback(Reason)
    /// Diarization is off in Settings (`speaker_mode = none`).
    case disabled
    /// Nothing to label (no segments).
    case nothingToLabel

    enum Reason: Equatable, Sendable {
        case modelMissing
        case overBudget
        case failed
        case spoolUnavailable
    }
}

/// Runs after the transcript is complete and before the meeting becomes `ready` (the `beforeReady` hook of
/// `MeetingSession`): diarize each track from its spool, assign speakers, write them. Whatever happens, the
/// transcript stays: a failure, a missing model or a track over the memory budget end in a fallback plan, never
/// in an error that would stop the meeting from becoming `ready`. The session deletes the spool afterwards, so
/// the spool goes only after a success or a deliberate fallback.
struct MeetingFinalizer: Sendable {
    let store: MeetingsStore
    let keys: MeetingKeys
    let spool: SpoolStorage
    /// `plugins.meetings.diarization`, read when the finalizer runs.
    let isEnabled: @Sendable () -> Bool
    /// The folder `ModelManager` installed the diarization package in; `nil` when it is not installed.
    let modelFolder: @Sendable () async -> URL?
    let makeDiarizer: @Sendable (URL) -> any Diarizer
    let budget: DiarizationBudget
    let onOutcome: @Sendable (Int64, DiarizationOutcome) -> Void
    let logger: Logger

    init(
        store: MeetingsStore, keys: MeetingKeys, spool: SpoolStorage, isEnabled: @escaping @Sendable () -> Bool,
        modelFolder: @escaping @Sendable () async -> URL?,
        makeDiarizer: @escaping @Sendable (URL) -> any Diarizer = { FluidDiarizer(modelFolder: $0) },
        budget: DiarizationBudget = DiarizationBudget(),
        onOutcome: @escaping @Sendable (Int64, DiarizationOutcome) -> Void = { _, _ in },
        logger: Logger = Logger(subsystem: "app.pounce", category: "meetings")
    ) {
        self.store = store
        self.keys = keys
        self.spool = spool
        self.isEnabled = isEnabled
        self.modelFolder = modelFolder
        self.makeDiarizer = makeDiarizer
        self.budget = budget
        self.onOutcome = onOutcome
        self.logger = logger
    }

    /// The closure for `MeetingSession(beforeReady:)`.
    var hook: @Sendable (Int64, UUID) async -> Void {
        { id, uuid in _ = await self.run(meetingID: id, uuid: uuid) }
    }

    @discardableResult
    func run(meetingID: Int64, uuid: UUID) async -> DiarizationOutcome {
        let outcome = await finalize(meetingID: meetingID, uuid: uuid)
        onOutcome(meetingID, outcome)
        return outcome
    }

    private func finalize(meetingID: Int64, uuid: UUID) async -> DiarizationOutcome {
        let segments: [SegmentRef]
        do {
            segments = try store.segmentRefs(meetingID: meetingID)
        } catch {
            logger.error("Diarization: the segments could not be read")
            return .fallback(.failed)
        }
        guard !segments.isEmpty else { return .nothingToLabel }
        guard isEnabled() else {
            _ = apply(SpeakerAssigner.none(), meetingID: meetingID, modelID: nil)
            return .disabled
        }
        guard let folder = await modelFolder() else {
            logger.notice("Diarization skipped: the model is not installed")
            return fallback(.modelMissing, segments: segments, meetingID: meetingID)
        }

        let diarizer = makeDiarizer(folder)
        var spans: [AudioChannel: [DiarizedSpan]] = [:]
        var failure: DiarizationOutcome.Reason?
        for channel in [AudioChannel.mic, .system] where segments.contains(where: { $0.channel == channel }) {
            do {
                spans[channel] = try await diarize(channel, uuid: uuid, with: diarizer)
            } catch let error as DiarizationError {
                logger.error("Diarization of the \(channel.rawValue, privacy: .public) track failed")
                failure = error == .modelsUnavailable ? .modelMissing : error.isOverBudget ? .overBudget : .failed
            } catch is SpoolError {
                logger.error("Diarization: the \(channel.rawValue, privacy: .public) spool could not be read")
                failure = .spoolUnavailable
            } catch {
                logger.error("Diarization of the \(channel.rawValue, privacy: .public) track failed")
                failure = .failed
            }
            if failure != nil || Task.isCancelled { break }
        }
        // Released right after use, on every path: the models are the large part of the memory.
        await diarizer.release()
        if let failure { return fallback(failure, segments: segments, meetingID: meetingID) }
        if Task.isCancelled { return fallback(.failed, segments: segments, meetingID: meetingID) }

        let plan = SpeakerAssigner.diarized(segments: segments, spans: spans)
        guard apply(plan, meetingID: meetingID, modelID: diarizer.modelID) else {
            return fallback(.failed, segments: segments, meetingID: meetingID)
        }
        logger.notice("Diarization finished: \(plan.speakers.count, privacy: .public) speakers")
        return .diarized(speakers: plan.speakers.count)
    }

    private func diarize(_ channel: AudioChannel, uuid: UUID, with diarizer: any Diarizer) async throws
        -> [DiarizedSpan]
    {
        guard let track = SpoolTrack(rawValue: channel.rawValue) else { throw DiarizationError.failed }
        let reader = try SpoolReader(file: spool.file(for: uuid, track: track), meeting: uuid, track: track, keys: keys)
        return try await diarizer.diarize(reader, maximumSamples: budget.maximumSamplesPerTrack)
    }

    private func fallback(_ reason: DiarizationOutcome.Reason, segments: [SegmentRef], meetingID: Int64)
        -> DiarizationOutcome
    {
        if !apply(SpeakerAssigner.channels(segments: segments), meetingID: meetingID, modelID: nil) {
            logger.error("Diarization: the fallback labels could not be written")
        }
        return .fallback(reason)
    }

    private func apply(_ plan: SpeakerPlan, meetingID: Int64, modelID: String?) -> Bool {
        do {
            try store.applySpeakerPlan(plan, meetingID: meetingID, diarizationModelID: modelID)
            return true
        } catch {
            return false
        }
    }
}

extension DiarizationError {
    fileprivate var isOverBudget: Bool {
        if case .overBudget = self { return true }
        return false
    }
}
