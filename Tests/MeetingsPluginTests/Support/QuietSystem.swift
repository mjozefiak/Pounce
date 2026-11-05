import Foundation
import LintelSpeech
import Testing

@testable import MeetingsPlugin

extension MeetingsSystem {
    /// Fakes for everything that reaches the screen, the speakers, the microphone and Core Audio. A plugin
    /// built with it records only `ScriptedSession`s and shows its HUDs to `RecordingHUD` and
    /// `RecordingSuggestionPresenter`.
    static var quiet: MeetingsSystem {
        MeetingsSystem(
            makeHUD: { _ in RecordingHUD() },
            makeSuggestionHUD: { _ in RecordingSuggestionPresenter() },
            makeProcessObserver: { ScriptedProcessObserver() },
            makeSelfTest: { SystemAudioSelfTest(backend: FakeBackend(), player: FakeTonePlayer()) },
            microphoneAuthorizer: { FakeAuthorizer(.notDetermined) },
            makeSession: { _, _ in ScriptedSession() })
    }

    /// Makes `quiet` what `MeetingsPlugin.init(context:)` uses, and fails the calling test when any test in
    /// this process has built a part of `live` (a HUD on the owner's screen, the test tone, a real recording).
    static func installQuiet(sourceLocation: SourceLocation = #_sourceLocation) {
        standard = quiet
        #expect(
            liveUses.isEmpty, "a test built the real \(liveUses.sorted()) (use MeetingsSystem.quiet)",
            sourceLocation: sourceLocation)
    }
}
