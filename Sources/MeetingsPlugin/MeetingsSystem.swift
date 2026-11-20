import Foundation
import LintelProviders
import LintelSpeech
import Synchronization

/// The parts of `MeetingsPlugin` that reach the screen, the speakers, the microphone and Core Audio: the
/// recording HUD, the suggestion HUD, the process observer of the suggestions, the system-audio test (it plays
/// a tone), the microphone permission and the real recording session. `live` is the app's.
///
/// Tests never use `live`: they pass their own to `MeetingsPlugin.init(context:authorizer:system:)` or, for a
/// plugin the shell builds from its type (`init(context:)`), set `standard` before. Every part of `live`
/// that is built is counted in `liveUses`, so a test support helper can assert that no test showed a HUD,
/// played the tone, asked for the microphone or recorded.
struct MeetingsSystem: Sendable {
    typealias HUDAction = @MainActor (MeetingHUDState.Action) -> Void
    typealias SuggestionHUDAction = @MainActor (SuggestionAction) -> Void

    var makeHUD: @MainActor @Sendable (@escaping HUDAction) -> any HUDPresenter
    var makeSuggestionHUD: @MainActor @Sendable (@escaping SuggestionHUDAction) -> any SuggestionPresenter
    var makeProcessObserver: @MainActor @Sendable () -> any ProcessAudioObserver
    var makeSelfTest: @MainActor @Sendable () -> SystemAudioSelfTest
    var microphoneAuthorizer: @MainActor @Sendable () -> any MicrophoneAuthorizer
    var makeSession: @MainActor @Sendable (MeetingsRuntime, MeetingSessionRequest) -> any RecordingSession
    /// The runner of the notes provider (the one way a process with a transcript starts). `live` can start the
    /// provider's CLI, and only for a provider the user chose in settings; tests get one over a fake process.
    /// `manualBinaryPath` is the CLI the user chose with "Choose File…" (a setting read at every use), or `nil`.
    var makeProviderRunner:
        @Sendable (_ cachesDirectory: URL, _ manualBinaryPath: @escaping @Sendable () -> String?) -> ProviderRunner

    /// The real HUD panels, Core Audio, the tone player, the system's microphone permission and sessions.
    static let live = MeetingsSystem(
        makeHUD: { action in
            countLiveUse("MeetingHUDPanel")
            return MeetingHUDPanel(onAction: action)
        },
        makeSuggestionHUD: { action in
            countLiveUse("SuggestionHUDPanel")
            return SuggestionHUDPanel(onAction: action)
        },
        makeProcessObserver: {
            countLiveUse("CoreAudioProcessObserver")
            return CoreAudioProcessObserver()
        },
        makeSelfTest: {
            countLiveUse("SystemAudioSelfTest")
            return SystemAudioSelfTest(backend: CoreAudioProcessTapBackend(), player: AVAudioEngineTonePlayer())
        },
        microphoneAuthorizer: {
            countLiveUse("SystemMicrophoneAuthorizer")
            return SystemMicrophoneAuthorizer()
        },
        makeSession: { runtime, request in
            countLiveUse("MeetingSession")
            return runtime.makeSession(request)
        },
        makeProviderRunner: { cachesDirectory, manualBinaryPath in
            countLiveUse("ProviderSystem")
            return ProviderRunner(
                system: ProviderSystem.live(homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
                cachesDirectory: cachesDirectory, manualBinaryPath: manualBinaryPath)
        })

    private static let standardValue = Mutex(MeetingsSystem.live)
    private static let liveUseNames = Mutex<Set<String>>([])

    /// What `MeetingsPlugin.init(context:)` uses: `live` in the app.
    static var standard: MeetingsSystem {
        get { standardValue.withLock { $0 } }
        set { standardValue.withLock { $0 = newValue } }
    }

    /// The parts of `live` built so far in this process.
    static var liveUses: Set<String> { liveUseNames.withLock { $0 } }

    private static func countLiveUse(_ name: String) {
        _ = liveUseNames.withLock { $0.insert(name) }
    }
}
