import Foundation
import PounceSpeech
import Synchronization
import os

/// What `MeetingController` needs from one recording. `MeetingSession` is the real one; tests script a fake.
protocol RecordingSession: Sendable {
    var events: AsyncStream<MeetingSessionEvent> { get }
    func start() async throws -> Int64
    func finish() async -> MeetingSessionOutcome
}

extension MeetingSession: RecordingSession {}

/// Everything the factory needs to build a recording. Real audio sources, the lease and the finalizer hook are
/// chosen by the factory; the controller only decides what to record.
struct MeetingSessionRequest {
    let store: MeetingsStore
    let keys: MeetingKeys
    let spool: SpoolStorage
    let modelID: String
    let modelFolder: URL
    /// False records the system audio only (the microphone was denied and the user chose to go on).
    let recordsMicrophone: Bool
    let recordsSystemAudio: Bool
    /// The app whose suggestion the user accepted, stored as `meeting.source_bundle_id`. `nil` for a recording
    /// started any other way.
    var sourceBundleID: String?
}

/// Where the speech model for the next recording is.
enum SpeechModelLookup: Equatable, Sendable {
    case ready(modelID: String, folder: URL)
    case missing
    /// A folder the user chose is gone.
    case unavailable
}

/// Runs a recording from the shortcut to the saved meeting (spec: Proposed Solution): the library check, the
/// model check, the microphone permission, the session, the HUD and the bookkeeping around it. Everything it
/// touches comes in through `Dependencies`, so the whole flow runs in tests with fakes.
///
/// Guarantees when the app quits or the plugin is switched off while recording (`shutDown()`): the session is
/// asked to finish, which closes the spool and writes what was heard; the controller waits for it at most
/// `shutdownTimeout`. A meeting that was not finished in time stays `processing` (or `recording`, if the
/// process dies before even that) and its spool is kept; the next start of the library turns it into
/// `incomplete` or resumes it (`RecoveryJob`), so at most the last ~2 s of audio (one spool frame) and the
/// text of segments not yet written are lost.
@MainActor
final class MeetingController {
    struct Dependencies {
        var library: MeetingsLibrary
        var settings: MeetingsSettings
        var authorizer: any MicrophoneAuthorizer
        var activity: MeetingActivity
        var speechModel: @MainActor () async -> SpeechModelLookup
        var makeSession: @MainActor (MeetingSessionRequest) -> any RecordingSession
        var hud: any HUDPresenter
        var clock: any Clock<Duration>
        var openSettings: @MainActor () -> Void
        var openURL: @MainActor (URL) -> Void
        var changed: @Sendable () -> Void = {}
        var logger = Logger(subsystem: "app.pounce", category: "meetings")
        /// How long the consent reminder stays on the HUD.
        var consentDuration: Duration = .seconds(8)
        /// How long the system track may stay silent before the HUD says so (spec: 20 s).
        var silentSystemAfter: Duration = .seconds(20)
        /// How long `shutDown()` waits for a running recording to finish.
        var shutdownTimeout: Duration = .seconds(20)
        /// How long a stop waits for the session's own `.finished` event after `finish()` returned, before it
        /// concludes from the returned outcome.
        var finishGrace: Duration = .seconds(2)
        /// Told about every change of the phase and every ignored late `start()` (tests wait on it instead of
        /// polling).
        var stateChanged: @MainActor () -> Void = {}
        /// The meeting detector (Phase 3), told when a recording runs, how loud it is and when it ends.
        var recordingObserver: (any MeetingRecordingObserver)?
    }

    enum Phase: Equatable {
        case idle
        /// The checks run or the session is starting.
        case preparing
        /// The microphone is denied and the HUD asks whether to record the system audio only.
        case awaitingMicrophoneDecision
        case recording
        /// Stopping and processing; a new recording waits for it.
        case finishing
    }

    /// A level above this on the system track counts as sound (permission denied gives exact zeros).
    static let signalThreshold: Float = 0.0001
    private static let microphonePrivacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    private let deps: Dependencies
    private(set) var phase = Phase.idle {
        didSet { if phase != oldValue { deps.stateChanged() } }
    }
    /// One per recording attempt. A task of an earlier attempt (a slow `start()`, a permission prompt that
    /// returns late) must not touch the state of a later one.
    private var runToken = 0
    private var finishTask: Task<Void, Never>?
    /// How often a `start()` returned after its attempt was over (tests).
    private(set) var ignoredStaleStarts = 0
    /// How many watcher timers ran out (tests wait on it instead of sleeping).
    private(set) var watcherFirings = 0
    private var session: (any RecordingSession)?
    private var meetingID: Int64?
    /// The app of the suggestion the user accepted for the attempt that is running; set by `begin` once its
    /// guards have passed, so a refused start never leaves it behind.
    private var sourceBundleID: String?
    /// Whether this controller holds one `MeetingActivity.begin()` (taken at the start, given back at the end).
    private var holdsActivity = false
    private var recording = MeetingHUDState.Recording()
    private var runTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var watchers: [Task<Void, Never>] = []
    private var sawSystemSignal = false
    private var lastShownLevels = (mic: Float(0), system: Float(0))

    init(_ dependencies: Dependencies) {
        deps = dependencies
    }

    var isBusy: Bool { phase != .idle }

    // MARK: Input

    /// The command: starts a recording, or ends the running one.
    func toggle() {
        switch phase {
        case .idle: start()
        case .recording, .preparing: stop()
        case .awaitingMicrophoneDecision:
            // Pressing again retries from the top (the permission may have been granted meanwhile).
            phase = .idle
            start()
        case .finishing: break
        }
    }

    /// Starts a recording. Ignored while one runs or is being processed.
    func start() {
        guard phase == .idle else { return }
        begin(systemOnly: false)
    }

    /// Starts a recording the user accepted from the meeting suggestion; `bundleID` is stored with the meeting
    /// (`meeting.source_bundle_id`) and nothing else is stored about the app. Ignored like `start()` while a
    /// recording runs or is being processed, and then nothing is stored.
    func start(fromSuggestionOf bundleID: String) {
        guard phase == .idle else { return }
        begin(systemOnly: false, source: bundleID)
    }

    /// Ends the recording; the meeting is processed and saved. While the recording is still being prepared
    /// (the checks, the microphone prompt) nothing exists yet and the attempt is cancelled; once the session
    /// exists, it is asked to finish (a session still starting finishes as soon as its start is done).
    func stop() {
        switch phase {
        case .recording: break
        case .preparing:
            guard session != nil else { return cancelPreparation() }
        default: return
        }
        guard let session else { return }
        phase = .finishing
        cancelWatchers()
        deps.hud.show(.finishing)
        requestFinish(session, token: runToken)
    }

    /// Gives back an attempt that has no session yet.
    private func cancelPreparation() {
        runToken += 1
        runTask?.cancel()
        releaseActivity()
        sourceBundleID = nil
        phase = .idle
        deps.hud.hide()
    }

    /// Asks the session to finish, once. When the session returns without having sent `.finished` (it never
    /// started, or the stream broke), the controller concludes from the returned outcome after a short grace.
    private func requestFinish(_ session: any RecordingSession, token: Int) {
        guard finishTask == nil else { return }
        let consumer = eventsTask
        finishTask = Task { [weak self] in
            let outcome = await session.finish()
            guard let self, self.runToken == token, self.session != nil else { return }
            if let consumer {
                await Self.wait(for: consumer, upTo: self.deps.finishGrace, on: self.deps.clock)
            }
            guard self.runToken == token, self.session != nil else { return }
            self.conclude(outcome)
        }
    }

    /// A button of the HUD.
    func perform(_ action: MeetingHUDState.Action) {
        switch action {
        case .stop: stop()
        case .openSettings: deps.openSettings()
        case .openMicrophoneSettings:
            if let url = Self.microphonePrivacyURL { deps.openURL(url) }
        case .recordSystemAudioOnly:
            guard phase == .awaitingMicrophoneDecision else { return }
            phase = .idle
            // The app of the suggestion (if any) stays with a system-audio-only recording.
            begin(systemOnly: true, source: sourceBundleID)
        case .dismiss:
            if phase == .preparing, session == nil { return cancelPreparation() }
            guard phase == .awaitingMicrophoneDecision else { return }
            sourceBundleID = nil
            phase = .idle
            deps.hud.hide()
        }
    }

    // MARK: Activity

    private func acquireActivity() {
        guard !holdsActivity else { return }
        holdsActivity = true
        deps.activity.begin()
    }

    private func releaseActivity() {
        guard holdsActivity else { return }
        holdsActivity = false
        deps.activity.end()
    }

    // MARK: Start

    private func begin(systemOnly: Bool, source: String? = nil) {
        // The activity is held from here until the meeting is over: before the model check, the spool folder,
        // the row and any lease exist (the contract of `MeetingActivity`).
        guard !deps.activity.isRemovingModel else { return fail(.modelBeingRemoved) }
        acquireActivity()
        sourceBundleID = source
        phase = .preparing
        deps.recordingObserver?.recordingPreparing()
        runToken += 1
        let token = runToken
        runTask = Task { [weak self] in await self?.run(systemOnly: systemOnly, token: token) }
    }

    /// Whether the attempt `token` is still the one being prepared.
    private func isPreparing(_ token: Int) -> Bool { token == runToken && phase == .preparing }

    /// Whether the session of attempt `token` is still this controller's (not concluded, not replaced).
    private func holdsSession(_ token: Int) -> Bool { token == runToken && session != nil }

    private func run(systemOnly: Bool, token: Int) async {
        guard isPreparing(token) else { return }
        let library = deps.library
        // Read once: the same answer decides the denied-microphone offer, the request and the pill.
        let recordsSystem = deps.settings.systemAudio
        guard library.canRecord, let store = library.store, let keys = library.keys else {
            return fail(.libraryUnavailable)
        }
        let modelID: String
        let folder: URL
        let lookup = await deps.speechModel()
        guard isPreparing(token) else { return }
        switch lookup {
        case .ready(let id, let url):
            modelID = id
            folder = url
        case .missing: return fail(.modelMissing)
        case .unavailable: return fail(.modelUnavailable)
        }

        if !systemOnly {
            switch deps.authorizer.status() {
            case .granted: break
            case .denied: return microphoneDenied(offersSystemOnly: recordsSystem)
            case .notDetermined:
                // The shortcut is the user's action: the prompt is allowed now.
                deps.hud.show(.allowMicrophone)
                let granted = await deps.authorizer.requestAccess()
                guard isPreparing(token) else { return }
                if !granted { return microphoneDenied(offersSystemOnly: recordsSystem) }
            }
        }

        let session = deps.makeSession(
            MeetingSessionRequest(
                store: store, keys: keys, spool: library.spoolStorage,
                modelID: modelID, modelFolder: folder, recordsMicrophone: !systemOnly,
                recordsSystemAudio: recordsSystem, sourceBundleID: sourceBundleID))
        self.session = session
        recording = MeetingHUDState.Recording()
        recording.recordsMicrophone = !systemOnly
        recording.recordsSystem = recordsSystem
        recording.showsConsent = deps.settings.consentReminder
        sawSystemSignal = false
        lastShownLevels = (0, 0)
        deps.hud.show(.recording(recording))
        let consumer = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        eventsTask = consumer

        let id: Int64
        do {
            id = try await session.start()
        } catch {
            // A session that already concluded (or a newer attempt) is none of this task's business.
            guard holdsSession(token) else { return ignoredStaleStart() }
            consumer.cancel()
            return abortStart(error)
        }
        // The session may have finished while it was still starting: then nothing is registered.
        guard holdsSession(token) else { return ignoredStaleStart() }
        meetingID = id
        library.registerLive(meetingID: id)
        if phase == .preparing {
            phase = .recording
            startWatchers(recordsSystem: recordsSystem)
            deps.recordingObserver?.recordingStarted(sourceBundleID: sourceBundleID)
        }
        deps.logger.info("Meeting recording started")
        // Until `.finished` arrives (or the stream is cancelled by a forced shutdown).
        await consumer.value
    }

    private func ignoredStaleStart() {
        ignoredStaleStarts += 1
        deps.stateChanged()
    }

    private func microphoneDenied(offersSystemOnly: Bool) {
        if offersSystemOnly {
            // Waiting for the user's decision holds nothing; `begin` takes the activity again.
            releaseActivity()
            phase = .awaitingMicrophoneDecision
            deps.hud.show(.problem(.microphoneDenied(offersSystemOnly: true)))
        } else {
            fail(.microphoneDenied(offersSystemOnly: false))
        }
    }

    private func abortStart(_ error: Error) {
        deps.logger.error(
            "Meeting recording could not start: \(String(describing: type(of: error)), privacy: .public)")
        let problem: MeetingHUDState.Problem
        switch error {
        case MeetingSessionError.anotherSessionActive: problem = .stillProcessing
        case MeetingSessionError.noAudioInput: problem = .noAudioInput
        case SpoolError.insufficientDiskSpace: problem = .lowDiskAtStart
        default: problem = .couldNotStart
        }
        endSession()
        deps.hud.show(.problem(problem))
    }

    private func fail(_ problem: MeetingHUDState.Problem) {
        releaseActivity()
        sourceBundleID = nil
        phase = .idle
        deps.hud.show(.problem(problem))
    }

    // MARK: Events

    private func handle(_ event: MeetingSessionEvent) {
        guard session != nil else { return }
        switch event {
        case .stateChanged(.finishing):
            enterFinishing()
            deps.hud.show(.finishing)
        case .stateChanged(.processing):
            enterFinishing()
            deps.hud.show(.processing(deps.settings.diarization ? .recognisingSpeakers : .closing))
        case .stateChanged:
            break
        case .level(let channel, let level):
            handleLevel(channel, level)
        case .elapsed(let seconds):
            recording.elapsedSeconds = seconds
            refresh()
        case .loadingModel:
            recording.loadingModel = true
            refresh()
        case .modelLoaded:
            recording.loadingModel = false
            refresh()
        case .modelUnavailable(let busy):
            recording.loadingModel = false
            recording.modelUnavailable = busy
            refresh()
        case .trackUnavailable(let channel):
            recording.unavailable.insert(channel)
            refresh()
        case .trackLost(let channel):
            recording.lost.insert(channel)
            refresh()
        case .spoolFailed, .databaseWriteFailed:
            recording.writeProblem = true
            refresh()
        case .lowDisk:
            recording.lowDisk = true
            refresh()
        case .limitApproaching(let secondsLeft):
            recording.secondsLeft = secondsLeft
            refresh()
        case .replaying(let remaining):
            enterFinishing()
            deps.hud.show(.processing(.transcribing(remaining: remaining)))
        case .limitReached, .echoMayRemain, .segmentSaved, .nothingHeard:
            break
        case .finished(let outcome):
            conclude(outcome)
        }
    }

    private func enterFinishing() {
        if phase == .recording || phase == .preparing {
            phase = .finishing
            cancelWatchers()
        }
    }

    private func handleLevel(_ channel: AudioChannel, _ level: Float) {
        deps.recordingObserver?.recordingLevel(channel, level)
        switch channel {
        case .mic: recording.micLevel = level
        case .system:
            recording.systemLevel = level
            if level > Self.signalThreshold {
                sawSystemSignal = true
                if recording.noSystemAudio { recording.noSystemAudio = false }
            }
        }
        // The meters are redrawn when they moved visibly, not on every chunk.
        let last = channel == .mic ? lastShownLevels.mic : lastShownLevels.system
        guard abs(level - last) >= 0.05 || (level == 0) != (last == 0) else { return }
        if channel == .mic { lastShownLevels.mic = level } else { lastShownLevels.system = level }
        refresh()
    }

    /// The recording pill shows the latest numbers, while the recording runs (or still starts).
    private func refresh() {
        guard session != nil, phase == .recording || phase == .preparing else { return }
        deps.hud.show(.recording(recording))
    }

    // MARK: Watchers

    private func startWatchers(recordsSystem: Bool) {
        let clock = deps.clock
        if recording.showsConsent {
            let delay = deps.consentDuration
            watchers.append(
                Task { [weak self] in
                    try? await clock.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    defer { self.watcherFired() }
                    guard self.phase == .recording else { return }
                    self.recording.showsConsent = false
                    self.refresh()
                })
        }
        if recordsSystem {
            let delay = deps.silentSystemAfter
            watchers.append(
                Task { [weak self] in
                    try? await clock.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    defer { self.watcherFired() }
                    guard self.phase == .recording, !self.sawSystemSignal, !self.recording.lost.contains(.system)
                    else { return }
                    self.recording.noSystemAudio = true
                    self.refresh()
                })
        }
    }

    private func watcherFired() {
        watcherFirings += 1
        deps.stateChanged()
    }

    private func cancelWatchers() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
    }

    // MARK: End

    private func conclude(_ outcome: MeetingSessionOutcome) {
        guard session != nil else { return }
        endSession()
        deps.library.refreshCount()
        deps.changed()
        deps.logger.info("Meeting recording ended")
        switch outcome.result {
        case .ready:
            deps.hud.show(.saved)
            if let id = outcome.meetingID { deps.library.meetingReady(id) }
        case .incomplete: deps.hud.show(.savedIncomplete)
        case .failed: deps.hud.show(.problem(.failed))
        case .discarded: deps.hud.show(.problem(.nothingHeard))
        case .notStarted: deps.hud.hide()
        }
    }

    /// Everything a recording holds, given back.
    private func endSession() {
        cancelWatchers()
        if let id = meetingID { deps.library.unregisterLive(meetingID: id) }
        releaseActivity()
        deps.recordingObserver?.recordingEnded()
        meetingID = nil
        sourceBundleID = nil
        session = nil
        eventsTask?.cancel()
        eventsTask = nil
        finishTask = nil
        phase = .idle
    }

    // MARK: Shut down

    /// The plugin is switched off or the app quits: a running recording is finished, bounded by
    /// `shutdownTimeout`; anything else is dropped. Returns whether nothing is left running.
    ///
    /// `false` means the session is still processing after the timeout. The controller does **not** forget it:
    /// the live meeting id and the activity stay until the session's own `.finished` arrives (so recovery,
    /// retention and Settings leave the meeting and its models alone), and `waitUntilEnded()` resolves then.
    /// The caller must keep the library open until that.
    @discardableResult
    func shutDown() async -> Bool {
        guard let session else {
            runToken += 1
            runTask?.cancel()
            runTask = nil
            releaseActivity()
            sourceBundleID = nil
            deps.recordingObserver?.recordingEnded()
            if phase != .idle {
                phase = .idle
                deps.hud.hide()
            }
            return true
        }
        cancelWatchers()
        enterFinishing()
        requestFinish(session, token: runToken)
        if let runTask {
            await Self.wait(for: runTask, upTo: deps.shutdownTimeout, on: deps.clock)
        }
        if self.session != nil {
            deps.logger.notice("A meeting was still being finished at shutdown; it stays registered until it ends")
            return false
        }
        runTask = nil
        deps.hud.hide()
        return true
    }

    /// Resolves when the recording that is running (or being finished) is over.
    func waitUntilEnded() async {
        await runTask?.value
    }

    /// Waits for `task` or the timeout, whichever comes first. The task itself is not cancelled.
    private static func wait(for task: Task<Void, Never>, upTo timeout: Duration, on clock: any Clock<Duration>) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = OneShot(continuation)
            let sleeper = Task {
                try? await clock.sleep(for: timeout)
                once.fire()
            }
            Task {
                await task.value
                sleeper.cancel()
                once.fire()
            }
        }
    }
}

/// Resumes a continuation exactly once, from whichever caller gets there first.
private final class OneShot: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Never>?>

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = Mutex(continuation)
    }

    func fire() {
        let taken = continuation.withLock { value -> CheckedContinuation<Void, Never>? in
            defer { value = nil }
            return value
        }
        taken?.resume()
    }
}

/// Lets the HUD's buttons and the command reach the controller, which exists while the plugin is active.
@MainActor
final class MeetingControllerRelay {
    var controller: MeetingController?
}
