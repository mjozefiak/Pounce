import Foundation
import PounceKit
import PounceSpeech
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct MeetingDetectorTests {
    @Test func theDetectorIsOffAndTheObserverUntouchedUntilStarted() throws {
        let rig = try DetectorRig()
        #expect(rig.detector.status == .off)
        #expect(rig.observer.startCount == 0)
        rig.detector.reconcile(enabled: false)
        #expect(rig.observer.startCount == 0)
    }

    @Test func aMeetingAppUsingTheMicrophoneForTenSecondsIsSuggestedOnce() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        #expect(rig.detector.status == .listening)
        await rig.send(1, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(9), wakes: 0)
        #expect(rig.presenter.prompts.isEmpty)
        await rig.advance(by: .seconds(1))
        #expect(rig.presenter.prompts == [.meeting(bundleID: "us.zoom.xos", appName: "Zoom")])
        // Same session: no second suggestion however long it goes on.
        await rig.send(2, "us.zoom.xos")
        await rig.settle()
        #expect(rig.presenter.prompts.count == 1)
        #expect(rig.startedFor.isEmpty && rig.stops == 0)
    }

    @Test func anAppTheUserAddedGetsItsInstalledName() async throws {
        let rig = try DetectorRig(settings: [
            "plugins.meetings.suggestMeetings": .bool(true),
            "plugins.meetings.suggestExtraBundleIDs": .stringArray(["com.google.Chrome"]),
        ])
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "com.google.Chrome.helper")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        let expected = SuggestionPrompt.meeting(bundleID: "com.google.Chrome", appName: "Name of com.google.Chrome")
        #expect(rig.presenter.prompts == [expected])
    }

    @Test func ownProcessAndUnlistedAppsGiveNothing() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "app.pounce")
        await rig.send(2, "com.google.Chrome")
        #expect(rig.clock.sleepers == 0)
        rig.clock.advance(by: .seconds(120))
        await rig.settle()
        #expect(rig.presenter.prompts.isEmpty)
    }

    @Test func stoppingBeforeTheThresholdCancelsTheSuggestion() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "us.zoom.xos")
        await rig.waitForTimer()
        rig.clock.advance(by: .seconds(5))
        await rig.send(1, nil, running: false)
        rig.clock.advance(by: .seconds(60))
        await rig.settle()
        #expect(rig.presenter.prompts.isEmpty)
    }

    @Test func nothingIsSuggestedWhilePounceIsBusy() async throws {
        let rig = try DetectorRig()
        rig.busy = true
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.prompts.isEmpty)
    }

    @Test func theHUDDisappearsAfterFifteenSecondsAndDoesNothing() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.hides == 0)
        await eventually("the hide timer waits") { rig.clock.sleepers >= 1 }
        await rig.advance(by: .seconds(14), wakes: 0)
        #expect(rig.presenter.hides == 0)
        await rig.advance(by: .seconds(1))
        #expect(rig.presenter.hides == 1)
        #expect(rig.startedFor.isEmpty && rig.stops == 0)
        #expect(rig.settings.suggestMutedBundleIDs.isEmpty)
        #expect(SuggestionPrompt.lifetime == .seconds(15))
    }

    // MARK: Buttons

    private func suggested(_ rig: DetectorRig, _ bundleID: String = "us.zoom.xos") async {
        rig.detector.reconcile(enabled: true)
        await rig.send(1, bundleID)
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
    }

    @Test func recordIsTheOnlyWayToStartAndItNamesTheApp() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        rig.detector.perform(.record)
        #expect(rig.startedFor == ["us.zoom.xos"])
        #expect(rig.presenter.hides == 1)
        // A second click on a HUD that is gone does nothing.
        rig.detector.perform(.record)
        #expect(rig.startedFor == ["us.zoom.xos"])
    }

    @Test func notNowChangesNothing() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        rig.detector.perform(.notNow)
        #expect(rig.startedFor.isEmpty)
        #expect(rig.settings.suggestMutedBundleIDs.isEmpty)
        #expect(rig.presenter.hides == 1)
    }

    @Test func muteSavesTheAppAndItIsNeverSuggestedAgain() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        rig.detector.perform(.muteApp)
        #expect(rig.settings.suggestMutedBundleIDs == ["us.zoom.xos"])
        #expect(rig.startedFor.isEmpty)
        // The mute is in the settings store: a new detector over the same settings honours it.
        await rig.send(1, nil, running: false)
        await rig.send(2, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.prompts.count == 1)
    }

    @Test func muteKeepsEarlierMutedAppsAndDoesNotDuplicate() async throws {
        let rig = try DetectorRig(settings: [
            "plugins.meetings.suggestMeetings": .bool(true),
            "plugins.meetings.suggestMutedBundleIDs": .stringArray(["com.hnc.Discord"]),
        ])
        await suggested(rig)
        rig.detector.perform(.muteApp)
        #expect(rig.settings.suggestMutedBundleIDs == ["com.hnc.Discord", "us.zoom.xos"])
    }

    // MARK: End of the meeting

    @Test func theEndQuestionIsAskedAfterSilenceAndNeverStopsByItself() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        rig.detector.perform(.record)
        rig.detector.recordingStarted(sourceBundleID: "us.zoom.xos")
        rig.detector.recordingLevel(.system, 0.4)
        await rig.send(1, nil, running: false)
        await rig.waitForTimer()
        await rig.advance(by: .seconds(59), wakes: 0)
        #expect(rig.presenter.prompts.count == 1)
        await rig.advance(by: .seconds(1))
        #expect(rig.presenter.last == .endRecording(appName: "Zoom"))
        #expect(rig.stops == 0)
        // Only the click stops.
        rig.detector.perform(.endRecording)
        #expect(rig.stops == 1)
    }

    @Test func keepRecordingAndTheTimeoutLeaveTheRecordingAlone() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "us.zoom.xos")
        rig.detector.recordingStarted(sourceBundleID: "us.zoom.xos")
        await rig.send(1, nil, running: false)
        await rig.waitForTimer()
        await rig.advance(by: .seconds(60))
        rig.detector.perform(.keepRecording)
        #expect(rig.stops == 0)
        await rig.settle()
        #expect(rig.stops == 0)
    }

    @Test func theQuestionIsDroppedWhenTheRecordingEndsFirst() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "us.zoom.xos")
        rig.detector.recordingStarted(sourceBundleID: "us.zoom.xos")
        await rig.send(1, nil, running: false)
        await rig.waitForTimer()
        await rig.advance(by: .seconds(60))
        #expect(rig.presenter.last == .endRecording(appName: "Zoom"))
        rig.detector.recordingEnded()
        #expect(rig.presenter.hides == 1)
    }

    @Test func aRecordingStartedAnyOtherWayIsNeverAskedAbout() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "us.zoom.xos")
        rig.detector.recordingStarted(sourceBundleID: nil)
        await rig.send(1, nil, running: false)
        rig.clock.advance(by: .seconds(600))
        await rig.settle()
        #expect(rig.presenter.prompts.isEmpty)
    }

    // MARK: Listening follows the setting

    @Test func turningTheSettingOffStopsListeningAndRemovesTheHUD() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        #expect(rig.observer.isListening)
        rig.detector.reconcile(enabled: false)
        #expect(!rig.observer.isListening)
        #expect(rig.observer.stopCount == 1)
        #expect(rig.detector.status == .off)
        #expect(rig.presenter.hides == 1)
        // Events after that are not heard; nothing is left scheduled.
        rig.observer.input(5, "us.zoom.xos")
        rig.clock.advance(by: .seconds(60))
        await rig.settleQueued()
        #expect(rig.presenter.prompts.count == 1)
        #expect(rig.clock.sleepers == 0)
    }

    @Test func turningItOnAgainStartsFreshWithoutOldState() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        rig.detector.reconcile(enabled: false)
        rig.detector.reconcile(enabled: true)
        #expect(rig.observer.startCount == 2)
        await rig.send(1, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.prompts.count == 2)
    }

    @Test func startingTwiceListensOnce() throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        rig.detector.reconcile(enabled: true)
        #expect(rig.observer.startCount == 1)
    }

    @Test func anUnavailableAPIReportsItAndNothingElseHappens() async throws {
        let rig = try DetectorRig(failure: .unavailable(-1))
        rig.detector.reconcile(enabled: true)
        #expect(rig.detector.status == .unavailable)
        #expect(rig.statuses == [.unavailable])
        #expect(!rig.detector.isListening)
        rig.detector.recordingStarted(sourceBundleID: "us.zoom.xos")
        rig.detector.recordingLevel(.mic, 1)
        rig.detector.recordingEnded()
        #expect(rig.presenter.prompts.isEmpty)
        // Switching it off gives the plain off state again.
        rig.detector.reconcile(enabled: false)
        #expect(rig.detector.status == .off)
    }
}
