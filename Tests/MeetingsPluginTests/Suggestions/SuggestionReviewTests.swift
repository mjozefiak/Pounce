import Foundation
import PounceKit
import PounceSpeech
import Testing

@testable import MeetingsPlugin

@MainActor
final class RecordingObserverSpy: MeetingRecordingObserver {
    private(set) var preparing = 0
    private(set) var started: [String?] = []
    private(set) var ended = 0

    func recordingPreparing() { preparing += 1 }
    func recordingStarted(sourceBundleID: String?) { started.append(sourceBundleID) }
    func recordingLevel(_ channel: AudioChannel, _ level: Float) {}
    func recordingEnded() { ended += 1 }
}

/// Fixes from the review of the detection phase: flapping, two apps at once, an observer that is slow or
/// silent, the lists, and what the controller tells the detector.
@MainActor
@Suite struct SuggestionReviewTests {
    // MARK: Controller

    @Test func aStartRefusedWhileAModelIsRemovedDoesNotLeakTheAppIntoTheNextRecording() async throws {
        let rig = try ControllerRig()
        let done = MeetingsModelUsage.live(activity: rig.activity, isProcessing: { false }).reserveRemoval()
        rig.controller.start(fromSuggestionOf: "us.zoom.xos")
        #expect(rig.hud.last == .problem(.modelBeingRemoved))
        #expect(rig.requests.isEmpty)
        done()
        rig.controller.start()
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == nil)
    }

    @Test func theAppOfTheSuggestionStaysWithASystemAudioOnlyRecording() async throws {
        let rig = try ControllerRig(access: .denied)
        rig.controller.start(fromSuggestionOf: "us.zoom.xos")
        await eventually("asked") { rig.controller.phase == .awaitingMicrophoneDecision }
        rig.controller.perform(.recordSystemAudioOnly)
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == "us.zoom.xos")
    }

    @Test func theDetectorIsToldWhenARecordingIsBeingPreparedAndWhenAShutdownDropsIt() async throws {
        let spy = RecordingObserverSpy()
        let rig = try ControllerRig(observer: spy)
        rig.controller.start()
        #expect(spy.preparing == 1)
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(spy.started == [nil])
        // A shutdown while only preparing (no session yet) also ends it for the detector.
        let preparing = try ControllerRig(access: .denied, observer: spy)
        preparing.controller.start()
        await eventually("asked") { preparing.controller.phase == .awaitingMicrophoneDecision }
        let endedBefore = spy.ended
        await preparing.controller.shutDown()
        #expect(spy.ended == endedBefore + 1)
        await rig.controller.shutDown()
    }

    // MARK: Policy: flapping

    private let config = SuggestionConfig(enabled: true, ownBundleID: "app.pounce")

    private func event(_ process: UInt32, _ bundleID: String?, _ running: Bool = true) -> ProcessAudioEvent {
        ProcessAudioEvent(processObjectID: process, bundleID: bundleID, isRunningInput: running)
    }

    @Test func aRestartWithinTheGraceIsTheSameSessionAndOneAfterItIsNew() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        #expect(policy.evaluate(now: .seconds(10), config: config, isBusy: false).count == 1)
        policy.handle(event(1, nil, false), now: .seconds(40), config: config)
        policy.handle(event(1, "us.zoom.xos"), now: .seconds(60), config: config)
        #expect(policy.evaluate(now: .seconds(80), config: config, isBusy: false).isEmpty)
        // Gone for 30 s or more: a new session.
        policy.handle(event(1, nil, false), now: .seconds(90), config: config)
        policy.handle(event(1, "us.zoom.xos"), now: .seconds(120), config: config)
        #expect(policy.evaluate(now: .seconds(129), config: config, isBusy: false).isEmpty)
        #expect(policy.evaluate(now: .seconds(130), config: config, isBusy: false).count == 1)
    }

    @Test func aRefusedSessionStaysRefusedAcrossAFlap() {
        var muted = config
        muted.mutedBundleIDs = ["US.Zoom.XOS"]
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: muted)
        #expect(policy.evaluate(now: .seconds(10), config: muted, isBusy: false).isEmpty)
        // Unmuted later during the same call and a flap: still no pill for this call.
        policy.handle(event(1, nil, false), now: .seconds(20), config: config)
        policy.handle(event(1, "us.zoom.xos"), now: .seconds(25), config: config)
        #expect(policy.evaluate(now: .seconds(60), config: config, isBusy: false).isEmpty)
    }

    @Test func removingAnAppFromTheListsCancelsItsPendingSuggestion() {
        var listed = config
        listed.extraBundleIDs = ["com.example.calls"]
        var policy = SuggestionPolicy()
        policy.handle(event(1, "com.example.calls"), now: .zero, config: listed)
        // The app is taken off the list before its 10 s.
        #expect(policy.evaluate(now: .seconds(10), config: config, isBusy: false).isEmpty)
        #expect(policy.nextWake(after: .seconds(10)) == nil)
    }

    @Test func bundleIDsMatchWithoutRegardToCase() {
        var listed = config
        listed.extraBundleIDs = ["com.Google.Chrome"]
        #expect(listed.listedApp(for: "COM.GOOGLE.CHROME.helper") == "com.Google.Chrome")
        #expect(listed.listedApp(for: "US.ZOOM.XOS") == "us.zoom.xos")
        #expect(KnownMeetingApp.name(of: "US.Zoom.xos") == "Zoom")
        var own = config
        own.ownBundleID = "App.Pounce"
        #expect(own.listedApp(for: "app.pounce.helper") == nil)
    }

    // MARK: Settings lists

    @Test func anAddedAppNeedsTwoDotsAndIsComparedWithoutCase() throws {
        let harness = try MeetingsHarness(settings: [:])
        let model = MeetingsPlugin(context: harness.context).ui.model
        for bad in ["com.apple", "apple.com.", "com..apple.x", "x"] {
            #expect(!model.addExtraApp(bad), "\(bad)")
        }
        #expect(model.addExtraApp("com.google.Chrome"))
        #expect(!model.addExtraApp("COM.GOOGLE.CHROME"))
        #expect(model.extraAppError == .duplicate)
    }

    @Test func storedListsAreValidatedAndCappedWhenRead() throws {
        let junk = ["com.apple", "not a bundle id", "com.ok.app", "COM.OK.APP", String(repeating: "a.", count: 200)]
        let many = (0..<80).map { "com.example.app\($0)" }
        let harness = try MeetingsHarness(settings: [
            "plugins.meetings.suggestExtraBundleIDs": .stringArray(junk + many),
            "plugins.meetings.suggestMutedBundleIDs": .stringArray(["Cisco-Systems.Spark", "bad id", "us.zoom.xos"]),
        ])
        let extra = harness.meetingsSettings.suggestExtraBundleIDs
        #expect(extra.count == MeetingsSettings.maximumExtraApps)
        #expect(extra.first == "com.ok.app")
        #expect(extra.filter { $0.lowercased() == "com.ok.app" }.count == 1)
        #expect(!extra.contains("com.apple"))
        #expect(harness.meetingsSettings.suggestMutedBundleIDs == ["Cisco-Systems.Spark", "us.zoom.xos"])
    }

    // MARK: Detector: flapping

    private func suggested(_ rig: DetectorRig, _ bundleID: String = "us.zoom.xos") async {
        rig.detector.reconcile(enabled: true)
        await rig.send(1, bundleID)
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
    }

    @Test func aFlapAfterNotNowMakesNoSecondPillButARejoinLaterDoes() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        rig.detector.perform(.notNow)
        await rig.send(1, nil, running: false)
        rig.clock.advance(by: .seconds(5))
        await rig.send(1, "us.zoom.xos")
        rig.clock.advance(by: .seconds(20))
        await rig.settle()
        #expect(rig.presenter.prompts.count == 1)
        // A real leave (longer than the grace) and a new call.
        await rig.send(1, nil, running: false)
        rig.clock.advance(by: .seconds(31))
        await rig.send(1, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.prompts.count == 2)
    }

    // MARK: Detector: two apps

    @Test func twoAppsReachingTenSecondsGiveOnePillAndTheOtherAfterItIsAnswered() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "com.microsoft.teams2")
        await rig.send(2, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.prompts == [.meeting(bundleID: "com.microsoft.teams2", appName: "Microsoft Teams")])
        rig.detector.perform(.notNow)
        #expect(rig.presenter.prompts.last == .meeting(bundleID: "us.zoom.xos", appName: "Zoom"))
        #expect(rig.presenter.prompts.count == 2)
    }

    @Test func theSecondAppIsOfferedWhenTheFirstPillTimesOut() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "com.microsoft.teams2")
        await rig.send(2, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        await eventually("the hide timer waits") { rig.clock.sleepers >= 1 }
        await rig.advance(by: .seconds(15))
        #expect(rig.presenter.prompts.count == 2)
        #expect(rig.presenter.last == .meeting(bundleID: "us.zoom.xos", appName: "Zoom"))
    }

    @Test func theSecondAppIsDroppedQuietlyWhenItLeavesBeforeThePillIsAnswered() async throws {
        let rig = try DetectorRig()
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "com.microsoft.teams2")
        await rig.send(2, "us.zoom.xos")
        await rig.waitForTimer()
        await rig.advance(by: .seconds(10))
        await rig.send(2, nil, running: false)
        rig.detector.perform(.notNow)
        #expect(rig.presenter.prompts.count == 1)
    }

    @Test func startingARecordingByHandRemovesAPillThatIsStillUp() async throws {
        let rig = try DetectorRig()
        await suggested(rig)
        #expect(rig.presenter.hides == 0)
        rig.detector.recordingPreparing()
        #expect(rig.presenter.hides == 1)
    }

    @Test func removingAnAppFromTheListsMidSessionCancelsThePendingSuggestion() async throws {
        let rig = try DetectorRig(settings: [
            "plugins.meetings.suggestMeetings": .bool(true),
            "plugins.meetings.suggestExtraBundleIDs": .stringArray(["com.example.calls"]),
        ])
        rig.detector.reconcile(enabled: true)
        await rig.send(1, "com.example.calls")
        await rig.waitForTimer()
        rig.settings.setSuggestExtraBundleIDs([])
        await rig.advance(by: .seconds(10))
        #expect(rig.presenter.prompts.isEmpty)
    }

    // MARK: Detector: what the observer reports

    @Test func aFailedInstallAfterStartingSwitchesSuggestionsOffAndStaysHarmless() async throws {
        let rig = try DetectorRig(observer: ScriptedProcessObserver(installFailure: .unavailable(-1)))
        rig.detector.reconcile(enabled: true)
        await eventually("unavailable") { rig.detector.status == .unavailable }
        #expect(!rig.detector.isListening)
        #expect(rig.observer.stopCount == 1)
        #expect(rig.presenter.prompts.isEmpty)
        rig.detector.reconcile(enabled: false)
        #expect(rig.detector.status == .off)
    }

    @Test func noProcessEverAnsweringIsReportedAsCannotConfirmAndClearsWhenOneDoes() async throws {
        let rig = try DetectorRig(observer: ScriptedProcessObserver(answered: false))
        rig.detector.reconcile(enabled: true)
        #expect(rig.detector.status == .listening)
        await eventually("the check waits") { rig.clock.sleepers >= 1 }
        rig.clock.advance(by: MeetingDetector.verificationDelay)
        await eventually("no data") { rig.detector.status == .noData }
        #expect(rig.detector.isListening)
        #expect(rig.presenter.prompts.isEmpty)
        // A process that answers later: events are handled and the status is honest again.
        await rig.send(1, "us.zoom.xos")
        #expect(rig.detector.status == .listening)
    }

    @Test func anObserverThatAnsweredIsNeverReportedAsNoData() async throws {
        let rig = try DetectorRig(observer: ScriptedProcessObserver(answered: true))
        rig.detector.reconcile(enabled: true)
        await eventually("the check waits") { rig.clock.sleepers >= 1 }
        rig.clock.advance(by: MeetingDetector.verificationDelay)
        await rig.settleQueued()
        await rig.settle()
        #expect(rig.detector.status == .listening)
    }

    // MARK: Plugin

    @Test func buildingASecondDetectorStopsTheFirst() async throws {
        let harness = try MeetingsHarness(settings: ["plugins.meetings.suggestMeetings": .bool(true)])
        let plugin = MeetingsPlugin(context: harness.context)
        let observer = ScriptedProcessObserver()
        plugin.adjustDetectorDependencies = {
            $0.observer = observer
            $0.presenter = RecordingSuggestionPresenter()
        }
        try await plugin.activate()
        #expect(observer.isListening)
        let first = try #require(plugin.detector)
        let second = plugin.makeDetector()
        #expect(first !== second)
        #expect(!first.isListening)
        #expect(observer.stopCount == 1)
        await plugin.deactivate()
    }
}
