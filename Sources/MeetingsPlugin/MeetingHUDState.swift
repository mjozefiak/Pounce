import Foundation

/// What the meeting HUD shows (spec: UI/UX → HUD recording). Pure data, so every state, its texts, its buttons
/// and its VoiceOver announcements are testable without a window. It carries counts, durations and levels,
/// never transcript text or audio.
enum MeetingHUDState: Equatable, Sendable {
    /// The microphone prompt is on screen.
    case allowMicrophone
    case recording(Recording)
    /// The recording ended and the transcript is being completed.
    case finishing
    case processing(Processing)
    /// The meeting is in the library.
    case saved
    /// The meeting is in the library but the transcript or the audio could not be finished; "Dokończ" can.
    case savedIncomplete
    case problem(Problem)

    /// What the recording pill knows. The first line is always the red dot, the time and the two meters.
    struct Recording: Equatable, Sendable {
        var elapsedSeconds = 0
        /// 0...1 loudness of the microphone ("Ja") and of the system audio.
        var micLevel: Float = 0
        var systemLevel: Float = 0
        /// Which tracks this recording has; a track that is off shows no meter.
        var recordsMicrophone = true
        var recordsSystem = true
        /// The speech model is still loading; recording already runs.
        var loadingModel = false
        /// The speech model could not be taken (`true`: another model is in use); the text comes after the
        /// meeting.
        var modelUnavailable: Bool?
        /// Seconds until the recording stops by itself, once the countdown has started.
        var secondsLeft: Int?
        /// The "tell the participants" line, shown in the first seconds only.
        var showsConsent = false
        /// No signal on the system track for the first 20 s.
        var noSystemAudio = false
        var lowDisk = false
        /// A track ended while recording (device unplugged, permission revoked, stalled).
        var lost: Set<AudioChannel> = []
        /// A track that could not be started at all.
        var unavailable: Set<AudioChannel> = []
        /// The library could not take a segment or the spool failed; the transcript may be incomplete.
        var writeProblem = false

        var notice: Notice? {
            if lowDisk { return .lowDisk }
            if writeProblem { return .writeProblem }
            if lost.contains(.mic) { return .deviceDisconnected }
            if lost.contains(.system) { return .systemAudioLost }
            if unavailable.contains(.mic), recordsMicrophone { return .deviceDisconnected }
            if unavailable.contains(.system) || noSystemAudio, recordsSystem { return .noSystemAudio }
            if let secondsLeft { return .limitCountdown(secondsLeft) }
            if let busy = modelUnavailable { return .modelUnavailable(busy: busy) }
            if loadingModel { return .loadingModel }
            if showsConsent { return .consent }
            return nil
        }
    }

    /// The second line of the recording pill.
    enum Notice: Equatable, Sendable {
        case lowDisk
        case writeProblem
        case deviceDisconnected
        case systemAudioLost
        case noSystemAudio
        case limitCountdown(Int)
        case modelUnavailable(busy: Bool)
        case loadingModel
        case consent
    }

    enum Processing: Equatable, Sendable {
        /// Speech is being turned into text from the spool (`remaining` segments left).
        case transcribing(remaining: Int)
        /// Speakers are being recognised and the meeting is being closed.
        case recognisingSpeakers
        /// Diarization is off: the meeting is only being closed.
        case closing
    }

    enum Problem: Equatable, Sendable {
        case modelMissing
        case modelUnavailable
        /// The Keychain refused (or the database failed): nothing can be recorded and nothing was deleted.
        case libraryUnavailable
        case microphoneDenied(offersSystemOnly: Bool)
        case noAudioInput
        case lowDiskAtStart
        /// A previous meeting is still being processed.
        case stillProcessing
        case nothingHeard
        case couldNotStart
        case failed
    }

    /// A button of the pill.
    enum Action: Equatable, Sendable {
        case stop
        case openSettings
        case openMicrophoneSettings
        case recordSystemAudioOnly
        case dismiss
    }
}

extension MeetingHUDState {
    var title: String {
        switch self {
        case .allowMicrophone:
            String(localized: "Allow the microphone", comment: "Meeting HUD while the microphone prompt is shown")
        case .recording:
            String(localized: "Recording a meeting", comment: "Meeting HUD while recording")
        case .finishing:
            String(localized: "Finishing…", comment: "Meeting HUD while the recording is being closed")
        case .processing(.transcribing(let remaining)):
            String(
                localized: "Processing: transcribing (\(remaining) left)",
                comment: "Meeting HUD while segments are transcribed after the meeting; the number is what is left")
        case .processing(.recognisingSpeakers):
            String(
                localized: "Processing: recognising speakers…",
                comment: "Meeting HUD while the speakers are recognised after the meeting")
        case .processing(.closing):
            String(localized: "Processing…", comment: "Meeting HUD while the meeting is being closed")
        case .saved:
            String(localized: "Meeting saved", comment: "Meeting HUD after the meeting was saved")
        case .savedIncomplete:
            String(
                localized: "Meeting saved – not complete",
                comment: "Meeting HUD when the transcript could not be finished")
        case .problem(let problem):
            Self.problemTitle(problem)
        }
    }

    private static func problemTitle(_ problem: Problem) -> String {
        switch problem {
        case .modelMissing:
            String(
                localized: "Download a speech model in Settings",
                comment: "Meeting HUD when no speech model is installed")
        case .modelUnavailable:
            String(localized: "Speech model unavailable", comment: "Meeting HUD when the model folder is gone")
        case .libraryUnavailable:
            String(
                localized: "The meetings library is unavailable",
                comment: "Meeting HUD when the library could not be opened (Keychain or database)")
        case .microphoneDenied(let offersSystemOnly):
            offersSystemOnly
                ? String(
                    localized: "Microphone not allowed. Record the system audio only?",
                    comment: "Meeting HUD when the microphone is denied but system audio can still be recorded")
                : String(localized: "Microphone not allowed", comment: "Meeting HUD when microphone access is denied")
        case .noAudioInput:
            String(localized: "No audio source could be started", comment: "Meeting HUD when no track could start")
        case .lowDiskAtStart:
            String(
                localized: "Not enough free disk space to record",
                comment: "Meeting HUD when the disk has less than 1.5 GB free")
        case .stillProcessing:
            String(
                localized: "The previous meeting is still being processed",
                comment: "Meeting HUD when a new recording is requested while one is being processed")
        case .nothingHeard:
            String(localized: "Nothing heard", comment: "Meeting HUD when the meeting was too short and silent")
        case .couldNotStart:
            String(localized: "The recording could not start", comment: "Meeting HUD when starting failed")
        case .failed:
            String(
                localized: "The meeting could not be saved",
                comment: "Meeting HUD when nothing of the meeting could be kept")
        }
    }

    /// The second line of the recording pill, when there is one. Messages have their buttons instead.
    var detail: String? {
        guard case .recording(let recording) = self else { return nil }
        return Self.noticeText(recording.notice)
    }

    private static func noticeText(_ notice: Notice?) -> String? {
        guard let notice else { return nil }
        switch notice {
        case .lowDisk:
            return String(
                localized: "Low disk space – the recording will end soon",
                comment: "Meeting HUD notice when free disk space runs low")
        case .writeProblem:
            return String(
                localized: "Some text could not be saved – you can finish it later",
                comment: "Meeting HUD notice when the library or the spool failed")
        case .deviceDisconnected:
            return String(
                localized: "Microphone disconnected", comment: "Meeting HUD notice when the microphone track ended")
        case .systemAudioLost:
            return String(
                localized: "System audio stopped", comment: "Meeting HUD notice when the system track ended")
        case .noSystemAudio:
            return String(
                localized: "Check the system audio recording permission",
                comment: "Meeting HUD notice when the system track stays silent for the first 20 seconds")
        case .limitCountdown(let seconds):
            let left = clock(seconds)
            return String(
                localized: "Recording ends in \(left)",
                comment: "Meeting HUD countdown before the 3 hour limit; minutes and seconds")
        case .modelUnavailable(let busy):
            return busy
                ? String(
                    localized: "Another speech model is in use – the text comes after the meeting",
                    comment: "Meeting HUD notice when dictation uses a different speech model")
                : String(
                    localized: "Speech model unavailable – the text comes after the meeting",
                    comment: "Meeting HUD notice when the speech model could not be loaded")
        case .loadingModel:
            return String(
                localized: "Loading the speech model – recording continues",
                comment: "Meeting HUD notice while the model loads")
        case .consent:
            return String(
                localized: "Tell the participants you are recording",
                comment: "Meeting HUD consent reminder in the first seconds")
        }
    }

    /// The buttons next to the text. The recording pill has "Zakończ" and, for notices that have a place to
    /// go, a link.
    var actions: [Action] {
        switch self {
        case .recording(let recording):
            switch recording.notice {
            case .noSystemAudio?: [.openSettings, .stop]
            default: [.stop]
            }
        case .problem(.modelMissing), .problem(.modelUnavailable), .problem(.libraryUnavailable):
            [.openSettings]
        case .problem(.microphoneDenied(let offersSystemOnly)):
            offersSystemOnly ? [.openMicrophoneSettings, .recordSystemAudioOnly, .dismiss] : [.openMicrophoneSettings]
        default:
            []
        }
    }

    func title(for action: Action) -> String {
        switch action {
        case .stop:
            String(localized: "End recording", comment: "Meeting HUD button that ends the recording")
        case .openSettings:
            String(localized: "Open Settings", comment: "Meeting HUD button that opens Settings")
        case .openMicrophoneSettings:
            String(
                localized: "Open Privacy settings", comment: "Meeting HUD button that opens the microphone privacy pane"
            )
        case .recordSystemAudioOnly:
            String(
                localized: "Record system audio only",
                comment: "Meeting HUD button that records without the microphone")
        case .dismiss:
            String(localized: "Cancel", comment: "Meeting HUD button that dismisses the message")
        }
    }

    var symbolName: String {
        switch self {
        case .allowMicrophone, .problem(.microphoneDenied), .problem(.noAudioInput): "mic.slash"
        case .recording: "record.circle.fill"
        case .finishing, .processing: "ellipsis"
        case .saved: "checkmark.circle.fill"
        case .savedIncomplete: "exclamationmark.circle"
        case .problem(.nothingHeard): "waveform.slash"
        case .problem: "exclamationmark.triangle"
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Whether the pill is the large two-meter recording layout.
    var showsMeters: Bool { isRecording }

    /// A pill with a detail line is taller.
    var hasDetailLine: Bool { detail != nil }

    /// How long a final state stays before the HUD disappears; `nil` while the state is live. A message with
    /// a decision in it stays longer.
    var hidesAfter: Duration? {
        switch self {
        case .saved: .seconds(3)
        case .savedIncomplete: .seconds(6)
        case .problem(.microphoneDenied(offersSystemOnly: true)): .seconds(20)
        case .problem: .seconds(5)
        default: nil
        }
    }

    /// What VoiceOver says when the state appears (spec: announcements on start and stop). Levels, the clock
    /// and the countdown tick stay silent; a new notice is read once.
    var announcement: String? {
        switch self {
        case .recording(let recording):
            if let notice = recording.notice, notice != .consent, notice != .loadingModel {
                if case .limitCountdown = notice { return nil }
                return Self.noticeText(notice)
            }
            return String(
                localized: "Meeting recording started",
                comment: "VoiceOver announcement when a meeting recording starts")
        case .finishing:
            return String(
                localized: "Meeting recording stopped",
                comment: "VoiceOver announcement when a meeting recording stops")
        case .saved, .savedIncomplete, .problem:
            return title
        default:
            return nil
        }
    }

    /// The label of the whole HUD for VoiceOver: the state, the time and the notice.
    var accessibilityLabel: String {
        switch self {
        case .recording(let recording):
            [title, Self.clock(recording.elapsedSeconds), detail].compactMap { $0 }.joined(separator: ". ")
        default:
            [title, detail].compactMap { $0 }.joined(separator: ". ")
        }
    }

    /// `m:ss`, or `h:mm:ss` from an hour on.
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
