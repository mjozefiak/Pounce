import Foundation
import Testing

@testable import MeetingsPlugin

/// The policy is pure: scripted events and a `Duration` as the clock.
@Suite struct SuggestionPolicyTests {
    private let config = SuggestionConfig(enabled: true, ownBundleID: "app.pounce")

    private func event(_ process: UInt32, _ bundleID: String?, _ running: Bool = true) -> ProcessAudioEvent {
        ProcessAudioEvent(processObjectID: process, bundleID: bundleID, isRunningInput: running)
    }

    private func evaluate(
        _ policy: inout SuggestionPolicy, at seconds: Double, config: SuggestionConfig? = nil, busy: Bool = false
    ) -> [SuggestionPolicy.Effect] {
        policy.evaluate(now: .seconds(seconds), config: config ?? self.config, isBusy: busy)
    }

    @Test func aKnownAppUsingTheMicrophoneForTenSecondsGetsOneSuggestion() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        #expect(evaluate(&policy, at: 9.9).isEmpty)
        #expect(policy.nextWake(after: .seconds(9.9)) == .seconds(10))
        #expect(evaluate(&policy, at: 10) == [.suggest(bundleID: "us.zoom.xos")])
        // One suggestion per mic-use session.
        #expect(evaluate(&policy, at: 11).isEmpty)
        #expect(evaluate(&policy, at: 600).isEmpty)
        #expect(policy.nextWake(after: .seconds(11)) == nil)
    }

    @Test func everyKnownAppIsListed() {
        let ids = KnownMeetingApp.all.map(\.bundleID)
        for id in [
            "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.tinyspeck.slackmacgap",
            "com.apple.FaceTime", "Cisco-Systems.Spark", "com.webex.meetingmanager", "com.hnc.Discord",
        ] {
            #expect(ids.contains(id), "\(id)")
        }
        // No browser by default.
        #expect(!ids.contains { $0.contains("Chrome") || $0.contains("Safari") || $0.contains("firefox") })
    }

    @Test func anInterruptionBeforeTenSecondsRestartsTheClock() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        policy.handle(event(1, nil, false), now: .seconds(6), config: config)
        #expect(evaluate(&policy, at: 12).isEmpty)
        #expect(policy.nextWake(after: .seconds(12)) == nil)
        policy.handle(event(1, "us.zoom.xos"), now: .seconds(12), config: config)
        #expect(evaluate(&policy, at: 21).isEmpty)
        #expect(evaluate(&policy, at: 22) == [.suggest(bundleID: "us.zoom.xos")])
    }

    @Test func aNewMicUseSessionOfTheSameAppIsSuggestedAgain() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        #expect(evaluate(&policy, at: 10).count == 1)
        policy.handle(event(1, nil, false), now: .seconds(100), config: config)
        policy.handle(event(1, "us.zoom.xos"), now: .seconds(200), config: config)
        #expect(evaluate(&policy, at: 210) == [.suggest(bundleID: "us.zoom.xos")])
    }

    @Test func helperProcessesOfOneAppAreOneSession() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        policy.handle(event(2, "us.zoom.xos.helper"), now: .seconds(5), config: config)
        #expect(evaluate(&policy, at: 10) == [.suggest(bundleID: "us.zoom.xos")])
        // One process stopping does not end the session while the other still runs.
        policy.handle(event(1, nil, false), now: .seconds(20), config: config)
        policy.handle(event(3, "us.zoom.xos"), now: .seconds(25), config: config)
        #expect(evaluate(&policy, at: 40).isEmpty)
    }

    @Test func anUnlistedAppNeverGetsASuggestion() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "com.apple.QuickTimePlayerX"), now: .zero, config: config)
        policy.handle(event(2, "com.example.unrelated"), now: .zero, config: config)
        policy.handle(event(3, nil), now: .zero, config: config)
        #expect(evaluate(&policy, at: 60).isEmpty)
        #expect(policy.nextWake(after: .zero) == nil)
    }

    @Test func aBrowserCountsOnlyWhenTheUserAddedIt() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "com.google.Chrome"), now: .zero, config: config)
        policy.handle(event(2, "com.google.Chrome.helper"), now: .zero, config: config)
        #expect(evaluate(&policy, at: 30).isEmpty)

        var added = config
        added.extraBundleIDs = ["com.google.Chrome"]
        policy.handle(event(3, "com.google.Chrome.helper"), now: .seconds(40), config: added)
        #expect(evaluate(&policy, at: 50, config: added) == [.suggest(bundleID: "com.google.Chrome")])
    }

    @Test func aMutedAppIsNotSuggestedButOthersAre() {
        var muted = config
        muted.mutedBundleIDs = ["us.zoom.xos"]
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: muted)
        policy.handle(event(2, "com.hnc.Discord"), now: .zero, config: muted)
        #expect(evaluate(&policy, at: 10, config: muted) == [.suggest(bundleID: "com.hnc.Discord")])
    }

    @Test func disabledSuggestionsMakeNoSuggestionAndTheSessionIsSpent() {
        var off = config
        off.enabled = false
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: off)
        #expect(evaluate(&policy, at: 10, config: off).isEmpty)
        // Turning them on mid-call does not suggest for a call that is already going.
        #expect(evaluate(&policy, at: 20).isEmpty)
    }

    @Test func nothingIsSuggestedWhilePounceRecordsOrFinishes() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        #expect(evaluate(&policy, at: 10, busy: true).isEmpty)
        // And not once the recording is over: it is the same mic-use session.
        #expect(evaluate(&policy, at: 30).isEmpty)
    }

    @Test func pounceItselfIsIgnored() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "app.pounce"), now: .zero, config: config)
        policy.handle(event(2, "app.pounce.helper"), now: .zero, config: config)
        #expect(evaluate(&policy, at: 60).isEmpty)
        // Even when the user listed it.
        var listed = config
        listed.extraBundleIDs = ["app.pounce"]
        policy.handle(event(3, "app.pounce"), now: .zero, config: listed)
        #expect(evaluate(&policy, at: 60, config: listed).isEmpty)
    }

    @Test func theLongestListedIDWins() {
        #expect(config.listedApp(for: "com.microsoft.teams2.helper") == "com.microsoft.teams2")
        #expect(config.listedApp(for: "com.microsoft.teams") == "com.microsoft.teams")
        #expect(config.listedApp(for: "us.zoom.xosx") == nil)
    }

    // MARK: End of the meeting

    @Test func theEndQuestionNeedsTheMicrophoneUseToEndAndSixtySecondsOfSilence() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        _ = evaluate(&policy, at: 10)
        policy.recordingStarted(source: "us.zoom.xos", now: .seconds(12))
        // The app still uses the microphone: no question however quiet it is.
        #expect(evaluate(&policy, at: 500).isEmpty)
        #expect(policy.nextWake(after: .seconds(500)) == nil)

        policy.handle(event(1, nil, false), now: .seconds(500), config: config)
        // Silent since 12 s: the question is due at once, not in the future.
        #expect(policy.nextWake(after: .seconds(500)) == nil)
        #expect(evaluate(&policy, at: 500) == [.askToEnd(bundleID: "us.zoom.xos")])
        // Asked once.
        #expect(evaluate(&policy, at: 900).isEmpty)
    }

    @Test func soundOnEitherTrackPostponesTheQuestion() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        policy.recordingStarted(source: "us.zoom.xos", now: .zero)
        policy.handle(event(1, nil, false), now: .seconds(100), config: config)
        policy.recordingLevel(0.3, now: .seconds(100))
        #expect(evaluate(&policy, at: 159.9).isEmpty)
        #expect(policy.nextWake(after: .seconds(159.9)) == .seconds(160))
        // A little noise below the sound level does not count.
        policy.recordingLevel(0.001, now: .seconds(150))
        #expect(evaluate(&policy, at: 160) == [.askToEnd(bundleID: "us.zoom.xos")])
    }

    @Test func aRecordingNotStartedFromASuggestionIsNeverAskedAbout() {
        var policy = SuggestionPolicy()
        policy.handle(event(1, "us.zoom.xos"), now: .zero, config: config)
        policy.recordingStarted(source: nil, now: .zero)
        policy.handle(event(1, nil, false), now: .seconds(10), config: config)
        #expect(evaluate(&policy, at: 1_000).isEmpty)
        #expect(policy.nextWake(after: .seconds(1_000)) == nil)
    }

    @Test func noQuestionAfterTheRecordingEnded() {
        var policy = SuggestionPolicy()
        policy.recordingStarted(source: "us.zoom.xos", now: .zero)
        policy.recordingEnded()
        #expect(evaluate(&policy, at: 1_000).isEmpty)
    }

    @Test func theEffectsOnlyAskThePolicyNeverStartOrStopAnything() {
        // The policy has no way to start or stop a recording: its whole output is `Effect`.
        let effects: [SuggestionPolicy.Effect] = [.suggest(bundleID: "a"), .askToEnd(bundleID: "a")]
        #expect(effects.count == 2)
    }
}
