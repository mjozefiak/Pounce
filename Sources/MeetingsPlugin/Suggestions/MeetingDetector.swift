import Foundation
import LintelSpeech
import os

/// The detector's view of time: a monotonic `Duration` and a sleep, taken from the plugin's clock. Tests give
/// it a manual clock.
struct DetectorClock: Sendable {
    let now: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init(_ clock: some Clock<Duration>) {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(for: $0) }
    }
}

/// Shows the suggestion HUD. The window in the app, a recording fake in tests.
@MainActor
protocol SuggestionPresenter: AnyObject {
    func show(_ prompt: SuggestionPrompt)
    func hide()
}

/// What `MeetingController` tells the detector about a recording (the controller does not know the
/// detector's type, only this).
@MainActor
protocol MeetingRecordingObserver: AnyObject {
    /// A recording is being prepared (the checks, the microphone prompt): any suggestion still up is moot.
    func recordingPreparing()
    /// A recording is running. `sourceBundleID` is set only when it was started from a suggestion.
    func recordingStarted(sourceBundleID: String?)
    func recordingLevel(_ channel: AudioChannel, _ level: Float)
    func recordingEnded()
}

/// Suggests recording a meeting when a known meeting app starts using the microphone (spec: Faza 3, Q6).
///
/// It listens only while it is `start`ed, which `MeetingsPlugin` does only while the plugin is active and
/// `plugins.meetings.suggestMeetings` is on. It sees process + bundle ID + "uses an input" and nothing else,
/// keeps that in memory, logs none of it, and **never starts or stops a recording by itself**: the HUD's
/// buttons call `Dependencies.startRecording` / `stopRecording`, which are the user's clicks. It registers no
/// global keys.
@MainActor
final class MeetingDetector: MeetingRecordingObserver {
    enum Status: Equatable, Sendable {
        /// Not listening (the setting is off or the plugin is inactive).
        case off
        case listening
        /// The Core Audio process API cannot be used here: suggestions are off, nothing else is affected.
        case unavailable
        /// Listening, but no process has answered the "uses an input" question for a while: Lintel cannot
        /// confirm that detection works on this Mac. Harmless; events that do arrive are still handled.
        case noData
    }

    /// How long the detector listens before it admits that no process answered.
    static let verificationDelay: Duration = .seconds(30)

    struct Dependencies {
        var observer: any ProcessAudioObserver
        var presenter: any SuggestionPresenter
        var clock: DetectorClock
        var settings: MeetingsSettings
        /// Lintel records a meeting or is still finishing one.
        var isBusy: @MainActor () -> Bool
        /// The user clicked "Nagrywaj" for `bundleID`.
        var startRecording: @MainActor (_ bundleID: String) -> Void
        /// The user agreed to end the recording.
        var stopRecording: @MainActor () -> Void
        /// A display name for an app that is not in the known list (the user added it).
        var appName: @MainActor (_ bundleID: String) -> String
        var ownBundleID: String?
        var statusChanged: @MainActor (Status) -> Void = { _ in }
        /// Told after every handled event and every timer, so tests wait on it instead of polling.
        var didProcess: @MainActor () -> Void = {}
        var logger = Logger(subsystem: "com.lintelapp", category: "meetings")
    }

    private let deps: Dependencies
    private var policy = SuggestionPolicy()
    private(set) var status = Status.off {
        didSet { if status != oldValue { deps.statusChanged(status) } }
    }
    private var subscription: ProcessAudioSubscription?
    private var eventsTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var scheduledWake: Duration?
    private var hideTask: Task<Void, Never>?
    private var verifyTask: Task<Void, Never>?
    private var shown: SuggestionPrompt?
    /// How many events and timer wakes were handled (tests).
    private(set) var processedCount = 0
    /// How many times the observer was started (tests).
    private(set) var startCount = 0

    init(_ dependencies: Dependencies) {
        deps = dependencies
    }

    /// Listening to the observer (also while the status says it cannot confirm detection).
    var isListening: Bool { subscription != nil }

    // MARK: Listening

    /// Starts or stops listening to match `enabled`. Idempotent.
    func reconcile(enabled: Bool) {
        if enabled {
            start()
            // The lists may have changed: an app taken off them cancels its pending suggestion.
            if isListening { evaluate() }
        } else {
            stop()
        }
    }

    func start() {
        guard subscription == nil else { return }
        startCount += 1
        do {
            let subscription = try deps.observer.start()
            self.subscription = subscription
            status = .listening
            eventsTask = Task { [weak self] in
                for await event in subscription.events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
            let generation = startCount
            let sleep = deps.clock.sleep
            verifyTask = Task { [weak self] in
                if let error = await subscription.installed() {
                    guard !Task.isCancelled, let self, self.startCount == generation else { return }
                    return self.installFailed(error)
                }
                guard let hasAnswered = subscription.hasAnswered else { return }
                try? await sleep(Self.verificationDelay)
                guard !Task.isCancelled, let self, self.startCount == generation, self.status == .listening
                else { return }
                if !hasAnswered() { self.status = .noData }
                self.deps.didProcess()
            }
        } catch {
            // Not an error to show: the feature is off on this Mac.
            deps.logger.notice("Meeting suggestions are unavailable on this Mac")
            status = .unavailable
        }
    }

    /// The listeners could not be installed (the observer says so after `start` returned).
    private func installFailed(_ error: ProcessAudioError) {
        deps.logger.notice("Meeting suggestions are unavailable on this Mac")
        tearDown()
        status = .unavailable
        deps.didProcess()
    }

    /// Stops listening, removes the HUD and forgets everything the policy saw.
    func stop() {
        tearDown()
        status = .off
    }

    private func tearDown() {
        subscription?.stop()
        subscription = nil
        eventsTask?.cancel()
        eventsTask = nil
        verifyTask?.cancel()
        verifyTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        scheduledWake = nil
        policy.reset()
        dismiss()
    }

    // MARK: Events

    private func config() -> SuggestionConfig {
        SuggestionConfig(
            enabled: deps.settings.suggestMeetings, mutedBundleIDs: Set(deps.settings.suggestMutedBundleIDs),
            extraBundleIDs: deps.settings.suggestExtraBundleIDs, ownBundleID: deps.ownBundleID)
    }

    private func handle(_ event: ProcessAudioEvent) {
        guard isListening else { return }
        // Something answered after all.
        if status == .noData { status = .listening }
        policy.handle(event, now: deps.clock.now(), config: config())
        evaluate()
        processedCount += 1
        deps.didProcess()
    }

    private func evaluate() {
        let now = deps.clock.now()
        let effects = policy.evaluate(now: now, config: config(), isBusy: deps.isBusy(), canSuggest: shown == nil)
        for effect in effects {
            switch effect {
            case .suggest(let bundleID):
                present(.meeting(bundleID: bundleID, appName: name(of: bundleID)))
            case .askToEnd(let bundleID):
                present(.endRecording(appName: name(of: bundleID)))
            }
        }
        reschedule(after: now)
    }

    private func name(of bundleID: String) -> String {
        KnownMeetingApp.name(of: bundleID) ?? deps.appName(bundleID)
    }

    /// One timer, for the policy's next moment of interest.
    private func reschedule(after now: Duration) {
        let next = policy.nextWake(after: now)
        guard next != scheduledWake else { return }
        wakeTask?.cancel()
        wakeTask = nil
        scheduledWake = next
        guard let next else { return }
        let delay = next - now
        let sleep = deps.clock.sleep
        wakeTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, self.isListening else { return }
            self.scheduledWake = nil
            self.evaluate()
            self.processedCount += 1
            self.deps.didProcess()
        }
    }

    // MARK: Recording (MeetingRecordingObserver)

    func recordingPreparing() {
        if case .meeting? = shown { dismiss() }
    }

    func recordingStarted(sourceBundleID: String?) {
        guard isListening else { return }
        policy.recordingStarted(source: sourceBundleID, now: deps.clock.now())
        reschedule(after: deps.clock.now())
        // A suggestion that is still up has been answered by the recording itself.
        if case .meeting? = shown { dismiss() }
    }

    func recordingLevel(_ channel: AudioChannel, _ level: Float) {
        guard isListening else { return }
        policy.recordingLevel(level, now: deps.clock.now())
    }

    func recordingEnded() {
        policy.recordingEnded()
        if case .endRecording? = shown { dismiss() }
        guard isListening else { return }
        reschedule(after: deps.clock.now())
    }

    // MARK: HUD

    private func present(_ prompt: SuggestionPrompt) {
        shown = prompt
        deps.presenter.show(prompt)
        hideTask?.cancel()
        let sleep = deps.clock.sleep
        hideTask = Task { [weak self] in
            try? await sleep(SuggestionPrompt.lifetime)
            guard !Task.isCancelled, let self, self.shown == prompt else { return }
            self.dismiss()
            // An app that reached its 10 s while this pill was up is offered now.
            if self.isListening { self.evaluate() }
            self.processedCount += 1
            self.deps.didProcess()
        }
    }

    private func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        guard shown != nil else { return }
        shown = nil
        deps.presenter.hide()
    }

    /// A button of the HUD. Each one is the user's click; nothing else reaches `startRecording` or
    /// `stopRecording`.
    func perform(_ action: SuggestionAction) {
        guard let prompt = shown else { return }
        dismiss()
        switch (prompt, action) {
        case (.meeting(let bundleID, _), .record):
            deps.startRecording(bundleID)
        case (.meeting(let bundleID, _), .muteApp):
            mute(bundleID)
        case (.endRecording, .endRecording):
            deps.stopRecording()
        default:
            break
        }
        // An app that reached its 10 s while this pill was up is offered after it is answered.
        if isListening { evaluate() }
    }

    private func mute(_ bundleID: String) {
        var muted = deps.settings.suggestMutedBundleIDs
        guard !muted.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) else { return }
        muted.append(bundleID)
        deps.settings.setSuggestMutedBundleIDs(muted)
    }
}
