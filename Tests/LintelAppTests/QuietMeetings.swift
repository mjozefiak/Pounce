import Foundation
import LintelSpeech
import Testing

@testable import MeetingsPlugin

/// The shell builds `MeetingsPlugin` from its type (`init(context:)`), so the tests cannot hand it fakes one
/// by one: every environment that builds plugins installs these instead (step 6.3c-fix-c). No HUD reaches the
/// screen, no tone plays, nothing asks for the microphone, reaches Core Audio or records.
enum QuietMeetings {
    static func install() {
        MeetingsSystem.standard = MeetingsSystem(
            makeHUD: { _ in SilentHUD() },
            makeSuggestionHUD: { _ in SilentSuggestionHUD() },
            makeProcessObserver: { UnavailableProcessObserver() },
            makeSelfTest: { SystemAudioSelfTest(backend: NoTapBackend(), player: NoTonePlayer()) },
            microphoneAuthorizer: { UnaskedMicrophone() },
            makeSession: { _, _ in RefusedSession() })
        #expect(
            MeetingsSystem.liveUses.isEmpty, "a test built the real \(MeetingsSystem.liveUses.sorted())")
    }
}

@MainActor
private final class SilentHUD: HUDPresenter {
    func show(_ state: MeetingHUDState) {}
    func hide() {}
}

@MainActor
private final class SilentSuggestionHUD: SuggestionPresenter {
    func show(_ prompt: SuggestionPrompt) {}
    func hide() {}
}

private struct UnavailableProcessObserver: ProcessAudioObserver {
    func start() throws(ProcessAudioError) -> ProcessAudioSubscription {
        throw .unavailable(0)
    }
}

private struct NoTonePlayer: TonePlayer {
    func play(duration: TimeInterval) async throws {
        throw SystemAudioError.unsupportedFormat
    }
}

private struct UnaskedMicrophone: MicrophoneAuthorizer {
    func status() -> MicrophoneAccess { .notDetermined }
    func requestAccess() async -> Bool { false }
}

private struct RefusedSession: RecordingSession {
    struct Refused: Error {}

    let events = AsyncStream<MeetingSessionEvent> { $0.finish() }

    func start() async throws -> Int64 { throw Refused() }
    func finish() async -> MeetingSessionOutcome { MeetingSessionOutcome(result: .ready, meetingID: 0) }
}

private struct NoTapBackend: ProcessTapBackend {
    func startTap(
        excludingOwnProcess: Bool, onBuffer: @escaping @Sendable (TapBuffer) -> Void
    ) throws(SystemAudioError) -> any ProcessTapSession {
        throw .tapUnavailable(0)
    }

    func observeOutputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) throws(SystemAudioError) -> any OutputChangeObservation {
        throw .tapUnavailable(0)
    }
}
