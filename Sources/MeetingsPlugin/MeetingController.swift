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
    private(set) var phase = Phase.idle
    private var session: (any RecordingSession)?
    private var meetingID: Int64?
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
        case .recording: stop()
        case .awaitingMicrophoneDecision:
            // Pressing again retries from the top (the permission may have been granted meanwhile).
            phase = .idle
            start()
        case .preparing, .finishing: break
        }
    }

    /// Starts a recording. Ignored while one runs or is being processed.
    func start() {
        guard phase == .idle else { return }
        begin(systemOnly: false)
    }

    /// Ends the recording; the meeting is processed and saved.
    func stop() {
        guard phase == .recording, let session else { return }
        phase = .finishing
        cancelWatchers()
        deps.hud.show(.finishing)
        Task { _ = await session.finish() }
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
            begin(systemOnly: true)
        case .dismiss:
            guard phase == .awaitingMicrophoneDecision else { return }
            phase = .idle
            deps.hud.hide()
        }
    }

    // MARK: Start

    private func begin(systemOnly: Bool) {
        phase = .preparing
        runTask = Task { [weak self] in await self?.run(systemOnly: systemOnly) }
    }

    private func run(systemOnly: Bool) async {
        let library = deps.library
        guard library.canRecord, let store = library.store, let keys = library.keys else {
            return fail(.libraryUnavailable)
        }
        let modelID: String
        let folder: URL
        switch await deps.speechModel() {
        case .ready(let id, let url):
            modelID = id
            folder = url
        case .missing: return fail(.modelMissing)
        case .unavailable: return fail(.modelUnavailable)
        }
        guard phase == .preparing, !Task.isCancelled else { return }

        if !systemOnly {
            switch deps.authorizer.status() {
            case .granted: break
            case .denied: return microphoneDenied()
            case .notDetermined:
                // The shortcut is the user's action: the prompt is allowed now.
                deps.hud.show(.allowMicrophone)
                let granted = await deps.authorizer.requestAccess()
                guard phase == .preparing, !Task.isCancelled else { return }
                if !granted { return microphoneDenied() }
            }
        }

        let recordsSystem = deps.settings.systemAudio
        let session = deps.makeSession(
            MeetingSessionRequest(
                store: store, keys: keys, spool: library.spoolStorage,
                modelID: modelID, modelFolder: folder, recordsMicrophone: !systemOnly,
                recordsSystemAudio: recordsSystem))
        self.session = session
        deps.activity.begin()
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
            consumer.cancel()
            return abortStart(error)
        }
        meetingID = id
        library.registerLive(meetingID: id)
        if phase == .preparing {
            phase = .recording
            startWatchers(recordsSystem: recordsSystem)
        }
        deps.logger.info("Meeting recording started")
        // Until `.finished` arrives (or the stream is cancelled by a forced shutdown).
        await consumer.value
    }

    private func microphoneDenied() {
        if deps.settings.systemAudio {
            phase = .awaitingMicrophoneDecision
            deps.hud.show(.problem(.microphoneDenied(offersSystemOnly: true)))
        } else {
            fail(.microphoneDenied(offersSystemOnly: false))
        }
    }

    private func abortStart(_ error: Error) {
        deps.logger.error("Meeting recording could not start: \(String(describing: error), privacy: .public)")
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
                    guard !Task.isCancelled, let self, self.phase == .recording else { return }
                    self.recording.showsConsent = false
                    self.refresh()
                })
        }
        if recordsSystem {
            let delay = deps.silentSystemAfter
            watchers.append(
                Task { [weak self] in
                    try? await clock.sleep(for: delay)
                    guard !Task.isCancelled, let self, self.phase == .recording, !self.sawSystemSignal,
                        !self.recording.lost.contains(.system)
                    else { return }
                    self.recording.noSystemAudio = true
                    self.refresh()
                })
        }
    }

    private func cancelWatchers() {
        for watcher in watchers { watcher.cancel() }
        watchers = []
    }

    // MARK: End

    private func conclude(_ outcome: MeetingSessionOutcome) {
        endSession()
        deps.library.refreshCount()
        deps.changed()
        deps.logger.info("Meeting recording ended")
        switch outcome.result {
        case .ready: deps.hud.show(.saved)
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
        if session != nil { deps.activity.end() }
        meetingID = nil
        session = nil
        eventsTask = nil
        phase = .idle
    }

    // MARK: Shut down

    /// The plugin is switched off or the app quits: a running recording is finished (bounded by
    /// `shutdownTimeout`), anything else is dropped.
    func shutDown() async {
        guard let session else {
            runTask?.cancel()
            runTask = nil
            if phase != .idle {
                phase = .idle
                deps.hud.hide()
            }
            return
        }
        cancelWatchers()
        Task { _ = await session.finish() }
        if let runTask {
            await Self.wait(for: runTask, upTo: deps.shutdownTimeout, on: deps.clock)
        }
        if self.session != nil {
            // Not done in time: the meeting stays for the recovery of the next start.
            deps.logger.notice("A meeting was still being finished at shutdown; recovery completes it")
            eventsTask?.cancel()
            endSession()
        }
        runTask = nil
        deps.hud.hide()
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
