import Foundation
import PounceKit
import PounceSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A process audio observer the test drives by hand. It never reaches Core Audio.
final class ScriptedProcessObserver: ProcessAudioObserver {
    private struct State {
        var starts = 0
        var stops = 0
        var failure: ProcessAudioError?
        var installFailure: ProcessAudioError?
        /// `nil`: the observer cannot tell whether any process answered.
        var answered: Bool?
        var continuation: AsyncStream<ProcessAudioEvent>.Continuation?
    }

    private let state = Mutex(State())

    init(
        failure: ProcessAudioError? = nil, installFailure: ProcessAudioError? = nil, answered: Bool? = nil
    ) {
        state.withLock {
            $0.failure = failure
            $0.installFailure = installFailure
            $0.answered = answered
        }
    }

    func setAnswered(_ value: Bool) { state.withLock { $0.answered = value } }

    var startCount: Int { state.withLock { $0.starts } }
    var stopCount: Int { state.withLock { $0.stops } }
    var isListening: Bool { state.withLock { $0.continuation != nil } }

    func start() throws(ProcessAudioError) -> ProcessAudioSubscription {
        let failure = state.withLock { state -> ProcessAudioError? in
            state.starts += 1
            return state.failure
        }
        if let failure { throw failure }
        let (events, continuation) = AsyncStream.makeStream(of: ProcessAudioEvent.self, bufferingPolicy: .unbounded)
        state.withLock { $0.continuation = continuation }
        let hasAnswers = state.withLock { $0.answered != nil }
        let stop: @Sendable () -> Void = { [self] in
            state.withLock { state in
                state.stops += 1
                state.continuation?.finish()
                state.continuation = nil
            }
        }
        let installed: @Sendable () async -> ProcessAudioError? = { [self] in state.withLock { $0.installFailure } }
        let ask: @Sendable () -> Bool = { [self] in state.withLock { $0.answered ?? false } }
        let answered: (@Sendable () -> Bool)? = hasAnswers ? ask : nil
        return ProcessAudioSubscription(events: events, stop: stop, installed: installed, hasAnswered: answered)
    }

    func send(_ event: ProcessAudioEvent) {
        _ = state.withLock { $0.continuation }?.yield(event)
    }

    func input(_ process: UInt32, _ bundleID: String?, running: Bool = true) {
        send(ProcessAudioEvent(processObjectID: process, bundleID: bundleID, isRunningInput: running))
    }
}

/// Records what the suggestion HUD was asked to show.
@MainActor
final class RecordingSuggestionPresenter: SuggestionPresenter {
    private(set) var prompts: [SuggestionPrompt] = []
    private(set) var hides = 0

    var last: SuggestionPrompt? { prompts.last }

    func show(_ prompt: SuggestionPrompt) {
        prompts.append(prompt)
        ChangeSignal.shared.fire()
    }

    func hide() {
        hides += 1
        ChangeSignal.shared.fire()
    }
}

/// The detector with fakes for everything it touches.
@MainActor
final class DetectorRig {
    let harness: MeetingsHarness
    let observer: ScriptedProcessObserver
    let presenter = RecordingSuggestionPresenter()
    let clock = ManualClock()
    var busy = false
    private(set) var detector: MeetingDetector!
    private(set) var startedFor: [String] = []
    private(set) var stops = 0
    private(set) var statuses: [MeetingDetector.Status] = []

    init(
        settings: [String: SettingValue] = ["plugins.meetings.suggestMeetings": .bool(true)],
        failure: ProcessAudioError? = nil, ownBundleID: String? = "app.pounce",
        observer: ScriptedProcessObserver? = nil
    ) throws {
        harness = try MeetingsHarness(settings: settings)
        self.observer = observer ?? ScriptedProcessObserver(failure: failure)
        detector = MeetingDetector(
            .init(
                observer: self.observer, presenter: presenter, clock: DetectorClock(clock),
                settings: harness.meetingsSettings,
                isBusy: { [unowned self] in self.busy },
                startRecording: { [unowned self] in self.startedFor.append($0) },
                stopRecording: { [unowned self] in self.stops += 1 },
                appName: { "Name of \($0)" }, ownBundleID: ownBundleID,
                statusChanged: { [unowned self] in self.statuses.append($0) },
                didProcess: { ChangeSignal.shared.fire() }))
    }

    var settings: MeetingsSettings { harness.meetingsSettings }

    /// Sends an event and waits until the detector has handled it.
    func send(_ process: UInt32, _ bundleID: String?, running: Bool = true) async {
        let before = detector.processedCount
        observer.input(process, bundleID, running: running)
        await eventually("the event is handled") { detector.processedCount > before }
    }

    /// Waits until the detector's timer is waiting on the clock.
    func waitForTimer() async {
        await eventually("a timer waits") { clock.sleepers >= 1 }
    }

    /// Advances the clock and waits until `count` more timer wakes were handled.
    func advance(by duration: Duration, wakes count: Int = 1) async {
        let before = detector.processedCount
        clock.advance(by: duration)
        guard count > 0 else { return await settleQueued() }
        await eventually("\(count) wake(s) handled") { detector.processedCount >= before + count }
    }

    func settleQueued() async {
        for _ in 0..<10 { await Task.yield() }
    }

    /// Lets everything that is already queued run, so "nothing happened" can be asserted.
    func settle() async {
        let marker = detector.processedCount
        observer.input(999_999, "com.example.unrelated")
        await eventually("the marker is handled") { detector.processedCount > marker }
        for _ in 0..<5 { await Task.yield() }
    }
}

extension ProcessAudioEvent {
    static let zoom = "us.zoom.xos"
}
