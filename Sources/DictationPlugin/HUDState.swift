import Foundation

/// What the dictation HUD shows (spec: UI/UX → HUD). Pure data, so every state, its texts and its
/// accessibility announcements are testable without a window.
enum HUDState: Equatable, Sendable {
    /// The microphone prompt is on screen.
    case allowMicrophone
    case recording(Recording)
    /// Recording ended; the text is being produced.
    case finishing
    case pasted
    /// Pasted, but some or all of the text is the raw transcript because formatting failed.
    case pastedUnformatted(all: Bool)
    case copied(TextPaster.CopyReason)
    case problem(Problem)

    struct Recording: Equatable, Sendable {
        /// 0...1 loudness.
        var level: Float = 0
        /// The model is still loading; recording already runs.
        var loadingModel = false
        /// Seconds until the recording stops by itself, once the countdown has started.
        var secondsLeft: Int?
        /// Whether Esc cancels; otherwise only the ✕ does.
        var escapeCancels = true
    }

    enum Problem: Equatable, Sendable {
        case modelMissing
        case modelUnavailable
        case modelFailedToLoad
        /// Another speech model (a meeting's) is in use, so dictation cannot load its own.
        case speechModelBusy
        case microphoneDenied
        case noMicrophone
        case nothingHeard
        /// "Paste the raw version" with nothing dictated yet.
        case nothingToPaste
    }
}

extension HUDState {
    var title: String {
        switch self {
        case .allowMicrophone:
            String(localized: "Allow the microphone", comment: "Dictation HUD while the microphone prompt is shown")
        case .recording(let recording):
            recording.loadingModel
                ? String(localized: "Loading model…", comment: "Dictation HUD while the speech model loads")
                : String(localized: "Recording", comment: "Dictation HUD while recording")
        case .finishing:
            String(localized: "Finishing…", comment: "Dictation HUD while the text is produced")
        case .pasted:
            String(localized: "Pasted", comment: "Dictation HUD after the text was pasted")
        case .pastedUnformatted(let all):
            all
                ? String(
                    localized: "Pasted – not cleaned up",
                    comment: "Dictation HUD when formatting failed and the raw text was pasted")
                : String(
                    localized: "Pasted – partly cleaned up",
                    comment: "Dictation HUD when formatting failed for some parts of the text")
        case .copied(.noAccessibility):
            String(
                localized: "Copied – allow Accessibility to paste",
                comment: "Dictation HUD when the text was only copied because Accessibility is missing")
        case .copied:
            String(localized: "Copied", comment: "Dictation HUD when the text was only copied")
        case .problem(.modelMissing):
            String(
                localized: "Download a speech model in Settings",
                comment: "Dictation HUD when no speech model is installed")
        case .problem(.modelUnavailable):
            String(localized: "Speech model unavailable", comment: "Dictation HUD when the model folder is gone")
        case .problem(.modelFailedToLoad):
            String(localized: "The speech model failed to load", comment: "Dictation HUD when loading the model failed")
        case .problem(.speechModelBusy):
            String(
                localized: "Another speech model is in use",
                comment: "Dictation HUD when a meeting uses a different speech model")
        case .problem(.microphoneDenied):
            String(localized: "Microphone not allowed", comment: "Dictation HUD when microphone access is denied")
        case .problem(.noMicrophone):
            String(localized: "No microphone found", comment: "Dictation HUD when there is no input device")
        case .problem(.nothingHeard):
            String(localized: "Nothing heard", comment: "Dictation HUD when the recording had no speech")
        case .problem(.nothingToPaste):
            String(
                localized: "No dictation to paste yet",
                comment: "Dictation HUD when there is no earlier dictation to paste again")
        }
    }

    /// The second line: how to cancel, or the countdown.
    var detail: String? {
        switch self {
        case .recording(let recording):
            if let left = recording.secondsLeft {
                return String(
                    localized: "Stops in \(left) s", comment: "Dictation HUD countdown before the recording limit")
            }
            return recording.escapeCancels
                ? String(localized: "Esc cancels", comment: "Dictation HUD hint")
                : String(localized: "✕ cancels", comment: "Dictation HUD hint when Escape could not be claimed")
        case .pastedUnformatted:
            return String(
                localized: "Raw version: Dictation → Paste raw version",
                comment: "Dictation HUD hint that the raw transcript can be pasted again")
        case .problem(.modelMissing), .problem(.modelUnavailable), .problem(.modelFailedToLoad),
            .problem(.microphoneDenied):
            return String(localized: "Open Settings", comment: "Dictation HUD button that opens Settings")
        default:
            return nil
        }
    }

    var symbolName: String {
        switch self {
        case .allowMicrophone, .problem(.microphoneDenied), .problem(.noMicrophone): "mic.slash"
        case .recording: "mic.fill"
        case .finishing: "ellipsis"
        case .pasted: "checkmark"
        case .pastedUnformatted: "exclamationmark.circle"
        case .copied: "doc.on.clipboard"
        case .problem(.nothingHeard): "waveform.slash"
        case .problem: "exclamationmark.triangle"
        }
    }

    /// Whether the ✕ is shown.
    var offersCancel: Bool {
        if case .recording = self { return true }
        return false
    }

    /// Whether the HUD's button leads to the speech model's download (`PluginContext.openModels`) rather than to
    /// Settings: the model problems.
    var opensModels: Bool {
        switch self {
        case .problem(.modelMissing), .problem(.modelUnavailable), .problem(.modelFailedToLoad): true
        default: false
        }
    }

    /// Whether the HUD has a button that opens Settings (the model and microphone problems).
    var offersSettings: Bool {
        switch self {
        case .problem(.modelMissing), .problem(.modelUnavailable), .problem(.modelFailedToLoad),
            .problem(.microphoneDenied):
            true
        default:
            false
        }
    }

    /// How long a final state stays before the HUD disappears; `nil` while the state is live.
    var hidesAfter: Duration? {
        switch self {
        case .pasted: .milliseconds(800)
        case .pastedUnformatted, .copied, .problem: .seconds(3)
        default: nil
        }
    }

    /// What VoiceOver says when the state appears (spec: announcements on start, stop and pasted). Level
    /// changes and the countdown tick stay silent.
    var announcement: String? {
        switch self {
        case .recording(let recording) where !recording.loadingModel && recording.secondsLeft == nil:
            String(localized: "Recording started", comment: "VoiceOver announcement when dictation starts")
        case .finishing:
            String(localized: "Recording stopped", comment: "VoiceOver announcement when dictation stops")
        case .pasted, .pastedUnformatted, .copied, .problem:
            title
        default:
            nil
        }
    }

    /// The label of the whole HUD for VoiceOver.
    var accessibilityLabel: String {
        [title, detail].compactMap { $0 }.joined(separator: ". ")
    }
}
