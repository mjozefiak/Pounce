import Foundation
import PounceKit
import PounceSpeech
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct MeetingControllerTests {
    // MARK: Activity contract

    @Test func startIsRefusedWhileAModelIsBeingRemoved() async throws {
        let rig = try ControllerRig()
        let done = MeetingsModelUsage.live(activity: rig.activity, isProcessing: { false }).reserveRemoval()
        #expect(rig.activity.isRemovingModel)
        rig.controller.start()
        #expect(rig.hud.last == .problem(.modelBeingRemoved))
        #expect(rig.controller.phase == .idle)
        #expect(rig.sessions.isEmpty)
        #expect(!rig.activity.isActive)
        #expect(rig.authorizer.requests == 0)

        done()
        await rig.startRecording()
        #expect(rig.activity.isActive)
    }

    @Test func theActivityIsHeldFromTheStartAndGivenBackWhenARefusalEndsIt() async throws {
        let rig = try ControllerRig()
        rig.lookup = .missing
        rig.controller.start()
        // Taken synchronously, before the model check, the spool folder, the row or a lease exist.
        #expect(rig.activity.isActive)
        await eventually { rig.hud.last == .problem(.modelMissing) }
        #expect(!rig.activity.isActive)
    }

    @Test func aPendingMicrophoneDecisionHoldsNoActivityAndAnotherStartTakesItAgain() async throws {
        let rig = try ControllerRig(access: .denied)
        rig.controller.start()
        await eventually { rig.controller.phase == .awaitingMicrophoneDecision }
        #expect(!rig.activity.isActive)
        rig.controller.perform(.recordSystemAudioOnly)
        #expect(rig.activity.isActive)
        await eventually { rig.controller.phase == .recording }
        #expect(rig.activity.sessions == 1)
    }

    // MARK: Refusals

    @Test func startIsRefusedWhenTheLibraryIsUnavailable() async throws {
        let rig = try ControllerRig(keychainError: .accessDenied)
        #expect(rig.library.status != .ready)
        rig.controller.start()
        await eventually { rig.hud.last == .problem(.libraryUnavailable) }
        #expect(rig.controller.phase == .idle)
        #expect(rig.sessions.isEmpty)
        #expect(!rig.activity.isActive)
        // Nothing was asked of the user and nothing deleted.
        #expect(rig.authorizer.requests == 0)
        #expect(rig.harness.keychain.deleteCount == 0)
    }

    @Test func startIsRefusedWithoutAModel() async throws {
        let rig = try ControllerRig()
        rig.lookup = .missing
        rig.controller.start()
        await eventually { rig.hud.last == .problem(.modelMissing) }
        #expect(rig.hud.last?.actions == [.openSettings])
        #expect(rig.sessions.isEmpty)
        #expect(rig.authorizer.requests == 0)
        #expect(rig.controller.phase == .idle)

        rig.lookup = .unavailable
        rig.controller.start()
        await eventually { rig.hud.last == .problem(.modelUnavailable) }
        #expect(rig.sessions.isEmpty)
    }

    @Test func startIsRefusedWhenTheMicrophoneIsDeniedAndSystemAudioIsOff() async throws {
        let rig = try ControllerRig(settings: ["plugins.meetings.systemAudio": .bool(false)], access: .denied)
        rig.controller.start()
        await eventually { rig.hud.last == .problem(.microphoneDenied(offersSystemOnly: false)) }
        #expect(rig.hud.last?.actions == [.openMicrophoneSettings])
        #expect(rig.sessions.isEmpty)
        #expect(rig.controller.phase == .idle)
        rig.controller.perform(.openMicrophoneSettings)
        #expect(rig.openedURLs.map(\.absoluteString).first?.hasSuffix("Privacy_Microphone") == true)
    }

    @Test func aDeniedMicrophoneOffersTheSystemTrackOnly() async throws {
        let rig = try ControllerRig(access: .denied)
        rig.controller.start()
        await eventually { rig.controller.phase == .awaitingMicrophoneDecision }
        #expect(rig.hud.last == .problem(.microphoneDenied(offersSystemOnly: true)))
        #expect(rig.hud.last?.actions == [.openMicrophoneSettings, .recordSystemAudioOnly, .dismiss])
        #expect(rig.sessions.isEmpty)

        rig.controller.perform(.recordSystemAudioOnly)
        await eventually { rig.controller.phase == .recording }
        let request = try #require(rig.requests.first)
        #expect(!request.recordsMicrophone)
        #expect(request.recordsSystemAudio)
        let flags = try #require(rig.lastRecordingFlags)
        #expect(flags.0 == false && flags.1 == true)
    }

    @Test func dismissingTheDecisionRecordsNothing() async throws {
        let rig = try ControllerRig(access: .denied)
        rig.controller.start()
        await eventually { rig.controller.phase == .awaitingMicrophoneDecision }
        rig.controller.perform(.dismiss)
        #expect(rig.controller.phase == .idle)
        #expect(rig.hud.hides == 1)
        #expect(rig.sessions.isEmpty)
        // Pressing the shortcut again asks again.
        rig.controller.toggle()
        await eventually { rig.controller.phase == .awaitingMicrophoneDecision }
    }

    @Test func theMicrophonePromptIsShownOnlyWhenNotDetermined() async throws {
        let rig = try ControllerRig(access: .notDetermined)
        await rig.startRecording()
        #expect(rig.authorizer.requests == 1)
        #expect(rig.hud.states.contains(.allowMicrophone))
        let granted = try ControllerRig(access: .granted)
        await granted.startRecording()
        #expect(granted.authorizer.requests == 0)
    }

    @Test func aRefusedPromptOffersTheSystemTrack() async throws {
        let rig = try ControllerRig(access: .notDetermined)
        rig.authorizer.deny()
        rig.controller.start()
        await eventually { rig.controller.phase == .awaitingMicrophoneDecision }
        #expect(rig.sessions.isEmpty)
    }

    // MARK: Start and stop

    @Test func aRecordingStartsWithTheRightRequest() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        let request = try #require(rig.requests.first)
        #expect(request.modelID == "parakeet-ultra")
        #expect(request.recordsMicrophone && request.recordsSystemAudio)
        #expect(request.modelFolder.lastPathComponent == "pounce-test-model")
        #expect(rig.session?.startCount == 1)
        #expect(rig.activity.isActive)
        #expect(rig.library.liveMeetingIDs == [7])
        #expect(rig.hud.lastRecording != nil)
    }

    @Test func theSystemTrackIsLeftOutWhenTheSettingIsOff() async throws {
        let rig = try ControllerRig(settings: ["plugins.meetings.systemAudio": .bool(false)])
        await rig.startRecording()
        #expect(rig.requests.first?.recordsSystemAudio == false)
        let flags = try #require(rig.lastRecordingFlags)
        #expect(flags.0 == true && flags.1 == false)
    }

    @Test func aSecondStartWhileRecordingIsIgnored() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.controller.start()
        rig.controller.perform(.recordSystemAudioOnly)
        await rig.settle()
        #expect(rig.sessions.count == 1)
        #expect(rig.controller.phase == .recording)
    }

    @Test func stoppingProcessesAndSavesTheMeeting() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.controller.toggle()
        await eventually { rig.controller.phase == .idle }
        await eventually { rig.hud.last == .saved }
        #expect(rig.session?.finishCount == 1)
        #expect(rig.hud.states.contains(.finishing))
        #expect(rig.hud.states.contains(.processing(.recognisingSpeakers)))
        #expect(!rig.activity.isActive)
        #expect(rig.library.liveMeetingIDs.isEmpty)
        #expect(rig.changes.get() >= 1)
        // A new recording can start once the previous one is over.
        rig.controller.start()
        await eventually { rig.sessions.count == 2 }
    }

    @Test func processingWithoutDiarizationSaysSo() async throws {
        let rig = try ControllerRig(settings: ["plugins.meetings.diarization": .bool(false)])
        await rig.startRecording()
        rig.controller.stop()
        await eventually { rig.hud.last == .saved }
        #expect(rig.hud.states.contains(.processing(.closing)))
        #expect(!rig.hud.states.contains(.processing(.recognisingSpeakers)))
    }

    @Test func aNewRecordingWaitsWhileTheLastOneIsBeingProcessed() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.stateChanged(.processing))
        await eventually { rig.controller.phase == .finishing }
        rig.controller.start()
        rig.controller.toggle()
        await rig.settle()
        #expect(rig.sessions.count == 1)
    }

    @Test(arguments: [
        (MeetingSessionOutcome.Result.ready, MeetingHUDState.saved),
        (.incomplete, .savedIncomplete),
        (.failed, .problem(.failed)),
        (.discarded, .problem(.nothingHeard)),
    ])
    func theOutcomeDecidesTheLastMessage(result: MeetingSessionOutcome.Result, expected: MeetingHUDState) async throws {
        let rig = try ControllerRig()
        rig.behaviour.outcome = MeetingSessionOutcome(result: result, meetingID: 7)
        await rig.startRecording()
        rig.controller.stop()
        await eventually { rig.hud.last == expected }
        #expect(rig.controller.phase == .idle)
    }

    @Test(arguments: [
        (MeetingSessionError.anotherSessionActive as any Error, MeetingHUDState.Problem.stillProcessing),
        (MeetingSessionError.noAudioInput, .noAudioInput),
        (SpoolError.insufficientDiskSpace(available: 1, required: 2), .lowDiskAtStart),
        (MeetingSessionError.database, .couldNotStart),
    ])
    func aFailedStartGivesEverythingBack(error: any Error, problem: MeetingHUDState.Problem) async throws {
        let rig = try ControllerRig()
        rig.behaviour.startError = error
        rig.controller.start()
        await eventually { rig.hud.last == .problem(problem) }
        #expect(rig.controller.phase == .idle)
        #expect(!rig.activity.isActive)
        #expect(rig.library.liveMeetingIDs.isEmpty)
        // And a retry is possible.
        rig.behaviour.startError = nil
        rig.controller.start()
        await eventually { rig.controller.phase == .recording }
    }

    // MARK: Shutdown

    @Test func switchingThePluginOffFinishesTheSession() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        await rig.controller.shutDown()
        #expect(rig.session?.finishCount == 1)
        #expect(rig.controller.phase == .idle)
        #expect(!rig.activity.isActive)
        #expect(rig.library.liveMeetingIDs.isEmpty)
        #expect(rig.hud.hides >= 1)
    }

    @Test func shuttingDownWithoutARecordingDropsPendingWork() async throws {
        let rig = try ControllerRig(access: .denied)
        rig.controller.start()
        await eventually { rig.controller.phase == .awaitingMicrophoneDecision }
        await rig.controller.shutDown()
        #expect(rig.controller.phase == .idle)
        #expect(rig.hud.hides >= 1)
        #expect(rig.sessions.isEmpty)
    }

    @Test func quittingWhileRecordingGivesUpAfterTheTimeoutAndLeavesTheRestToRecovery() async throws {
        let rig = try ControllerRig(shutdownTimeout: .seconds(5))
        rig.behaviour.hangsOnFinish = true
        await rig.startRecording()
        let done = Shared(false)
        let task = Task { @MainActor in
            await rig.controller.shutDown()
            done.update { $0 = true }
        }
        // The watchers are cancelled, so the only sleeper left is the shutdown timeout.
        await eventually("the shutdown waits on the clock") {
            rig.session?.finishCount == 1 && rig.clock.sleepers == 1
        }
        #expect(!done.get())
        rig.clock.advance(by: .seconds(5))
        await task.value
        #expect(done.get())
        // Everything the controller held is given back; the meeting stays for `RecoveryJob`.
        #expect(rig.controller.phase == .idle)
        #expect(!rig.activity.isActive)
        #expect(rig.library.liveMeetingIDs.isEmpty)
        #expect(rig.hud.hides >= 1)
    }

    // MARK: HUD content

    @Test func theConsentLineShowsInTheFirstSecondsOnly() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        #expect(rig.hud.lastRecording?.showsConsent == true)
        #expect(rig.hud.last?.detail == "Tell the participants you are recording")
        await eventually("the watchers") { rig.clock.sleepers >= 2 }
        rig.clock.advance(by: .seconds(8))
        await eventually { rig.hud.lastRecording?.showsConsent == false }
        #expect(rig.hud.last?.detail == nil)
    }

    @Test func theConsentLineIsOffWhenTheSettingIsOff() async throws {
        let rig = try ControllerRig(settings: ["plugins.meetings.consentReminder": .bool(false)])
        await rig.startRecording()
        #expect(rig.hud.states.allSatisfy { ($0.detail ?? "") != "Tell the participants you are recording" })
        #expect(rig.hud.lastRecording?.showsConsent == false)
    }

    @Test func lowDiskIsShown() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.lowDisk)
        await eventually { rig.hud.lastRecording?.lowDisk == true }
        #expect(rig.hud.lastRecording?.notice == .lowDisk)
    }

    @Test func aDisconnectedDeviceIsShownAndTheOtherTrackCarriesOn() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.trackLost(.mic))
        await eventually { rig.hud.lastRecording?.notice == .deviceDisconnected }
        #expect(rig.controller.phase == .recording)
    }

    @Test func theSystemTrackStaysSilentFor20SecondsAndTheHUDSaysSo() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        await eventually("the watchers") { rig.clock.sleepers >= 2 }
        rig.session?.send(.level(.mic, 0.4))
        rig.session?.send(.level(.system, 0))
        rig.clock.advance(by: .seconds(19))
        await rig.settle()
        #expect(rig.hud.lastRecording?.noSystemAudio == false)
        rig.clock.advance(by: .seconds(1))
        await eventually { rig.hud.lastRecording?.noSystemAudio == true }
        #expect(rig.hud.lastRecording?.notice == .noSystemAudio)
        #expect(rig.hud.last?.detail == "Check the system audio recording permission")
        #expect(rig.hud.last?.actions == [.openSettings, .stop])
        rig.controller.perform(.openSettings)
        #expect(rig.settingsOpened == 1)
        // Sound arriving later clears the hint.
        rig.session?.send(.level(.system, 0.3))
        await eventually { rig.hud.lastRecording?.noSystemAudio == false }
    }

    @Test func soundOnTheSystemTrackBeforeTheDeadlineKeepsTheHUDQuiet() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        await eventually("the watchers") { rig.clock.sleepers >= 2 }
        rig.session?.send(.level(.system, 0.2))
        await rig.settle()
        rig.clock.advance(by: .seconds(30))
        await rig.settle()
        #expect(rig.hud.lastRecording?.noSystemAudio == false)
    }

    @Test func noSystemWatcherWhenOnlyTheMicrophoneIsRecorded() async throws {
        let rig = try ControllerRig(settings: ["plugins.meetings.systemAudio": .bool(false)])
        await rig.startRecording()
        rig.clock.advance(by: .seconds(60))
        await rig.settle()
        #expect(rig.hud.lastRecording?.noSystemAudio == false)
        #expect(rig.hud.lastRecording?.notice != .noSystemAudio)
    }

    @Test func theLimitCountdownIsShown() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.limitApproaching(secondsLeft: 540))
        await eventually { rig.hud.lastRecording?.secondsLeft == 540 }
        #expect(rig.hud.last?.detail == "Recording ends in 9:00")
        rig.session?.send(.limitApproaching(secondsLeft: 539))
        await eventually { rig.hud.lastRecording?.secondsLeft == 539 }
        #expect(rig.hud.last?.detail == "Recording ends in 8:59")
    }

    @Test func theModelLoadingIsShownWhileRecordingContinues() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.loadingModel)
        await eventually { rig.hud.lastRecording?.loadingModel == true }
        #expect(rig.controller.phase == .recording)
        rig.session?.send(.modelLoaded)
        await eventually { rig.hud.lastRecording?.loadingModel == false }
        rig.session?.send(.modelUnavailable(busy: true))
        await eventually { rig.hud.lastRecording?.modelUnavailable == true }
        #expect(rig.hud.lastRecording?.notice == .modelUnavailable(busy: true))
    }

    @Test func theElapsedTimeAndLevelsReachTheHUD() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.level(.mic, 0.6))
        rig.session?.send(.level(.system, 0.3))
        rig.session?.send(.elapsed(seconds: 65))
        await eventually { rig.hud.lastRecording?.elapsedSeconds == 65 }
        let recording = try #require(rig.hud.lastRecording)
        #expect(recording.micLevel == 0.6)
        #expect(recording.systemLevel == 0.3)
        #expect(rig.hud.last?.accessibilityLabel.contains("1:05") == true)
    }

    @Test func aSessionThatEndsByItselfIsConcluded() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.session?.send(.stateChanged(.finishing))
        rig.session?.send(.finished(MeetingSessionOutcome(result: .incomplete, meetingID: 7)))
        await eventually { rig.controller.phase == .idle }
        #expect(rig.hud.last == .savedIncomplete)
        #expect(!rig.activity.isActive)
        #expect(rig.library.liveMeetingIDs.isEmpty)
    }

    @Test func theLibraryRefusesToFinishALiveMeeting() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        #expect(rig.library.finish(meetingID: 7) == nil)
        // Live ids survive `close()` (a session outlives a disable and re-enable); the session's end clears them.
        rig.library.close()
        #expect(rig.library.liveMeetingIDs == [7])
        rig.session?.send(.stateChanged(.finishing))
        rig.session?.send(.finished(MeetingSessionOutcome(result: .incomplete, meetingID: 7)))
        await eventually { rig.controller.phase == .idle }
        #expect(rig.library.liveMeetingIDs.isEmpty)
    }
}

extension ControllerRig {
    /// Which tracks the latest recording pill shows.
    var lastRecordingFlags: (Bool, Bool)? {
        hud.lastRecording.map { ($0.recordsMicrophone, $0.recordsSystem) }
    }
}
