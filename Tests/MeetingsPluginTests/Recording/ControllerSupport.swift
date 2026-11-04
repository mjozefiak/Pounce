import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

/// A clock that moves only when the test says so. Sleepers wake in the order of their deadlines.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Waiter {
        let id: Int
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct State {
        var now = Duration.zero
        var nextID = 0
        var waiters: [Waiter] = []
        var cancelled: Set<Int> = []
    }

    private let state = Mutex(State())

    var now: Instant { Instant(offset: state.withLock { $0.now }) }
    var minimumResolution: Duration { .milliseconds(1) }

    /// How many tasks are waiting on the clock.
    var sleepers: Int { state.withLock { $0.waiters.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let action = state.withLock { state -> Result<Void, CancellationError>? in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline.offset <= state.now { return .success(()) }
                    state.waiters.append(Waiter(id: id, deadline: deadline.offset, continuation: continuation))
                    return nil
                }
                switch action {
                case .success?: continuation.resume()
                case .failure(let error)?: continuation.resume(throwing: error)
                case nil: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Waiter] in
            state.now += duration
            let ready = state.waiters.filter { $0.deadline <= state.now }.sorted { $0.deadline < $1.deadline }
            state.waiters.removeAll { $0.deadline <= state.now }
            return ready
        }
        for waiter in due { waiter.continuation.resume() }
    }
}

/// Wakes tests that wait for a change instead of polling for it. Fired by the HUD, the controller's phase and
/// the scripted sessions; a woken test re-checks its condition.
@MainActor
final class ChangeSignal {
    static let shared = ChangeSignal()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fire() {
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    nonisolated static func fireFromAnywhere() {
        Task { @MainActor in shared.fire() }
    }
}

/// A one-way latch a test opens to let a scripted session go on.
final class Latch: Sendable {
    private struct State {
        var open = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// Records what the HUD was asked to show.
@MainActor
final class RecordingHUD: HUDPresenter {
    private(set) var states: [MeetingHUDState] = []
    private(set) var hides = 0

    var last: MeetingHUDState? { states.last }

    var lastRecording: MeetingHUDState.Recording? {
        for state in states.reversed() {
            if case .recording(let recording) = state { return recording }
        }
        return nil
    }

    func show(_ state: MeetingHUDState) {
        states.append(state)
        ChangeSignal.shared.fire()
    }

    func hide() {
        hides += 1
        ChangeSignal.shared.fire()
    }
}

/// A recording the test drives by hand: it sends events and decides how `start()` and `finish()` end.
final class ScriptedSession: RecordingSession {
    struct Behaviour {
        var startError: (any Error)?
        var meetingID: Int64 = 7
        var outcome = MeetingSessionOutcome(result: .ready, meetingID: 7)
        /// `finish()` waits forever (a shutdown that does not complete in time).
        var hangsOnFinish = false
        /// Sent before anything else in `start()`.
        var eventsBeforeStart: [MeetingSessionEvent] = []
        /// `start()` waits for this latch (a slow start: spool, row, audio).
        var startLatch: Latch?
        /// `finish()` waits for this latch, then finishes normally (a slow processing).
        var finishLatch: Latch?
        /// `start()` sends `.finished` (and ends the stream) before it returns: the session ended while starting.
        var finishesDuringStart = false
        /// `finish()` returns the outcome but sends no `.finished`.
        var omitsFinished = false
        /// With `omitsFinished`: the stream still ends.
        var endsStreamWithoutFinished = true
    }

    let events: AsyncStream<MeetingSessionEvent>
    private let continuation: AsyncStream<MeetingSessionEvent>.Continuation
    private let counts = Mutex((starts: 0, finishes: 0))
    private let behaviour: Behaviour
    private let startReturned = Latch()

    init(_ behaviour: Behaviour = Behaviour()) {
        self.behaviour = behaviour
        (events, continuation) = AsyncStream.makeStream(of: MeetingSessionEvent.self, bufferingPolicy: .unbounded)
    }

    var startCount: Int { counts.withLock { $0.starts } }
    var finishCount: Int { counts.withLock { $0.finishes } }

    func send(_ event: MeetingSessionEvent) { continuation.yield(event) }

    func waitForStartToReturn() async { await startReturned.wait() }

    func start() async throws -> Int64 {
        defer { startReturned.open() }
        counts.withLock { $0.starts += 1 }
        ChangeSignal.fireFromAnywhere()
        for event in behaviour.eventsBeforeStart { continuation.yield(event) }
        await behaviour.startLatch?.wait()
        if let error = behaviour.startError { throw error }
        if behaviour.finishesDuringStart {
            continuation.yield(.stateChanged(.finishing))
            continuation.yield(.finished(behaviour.outcome))
            continuation.finish()
            return behaviour.meetingID
        }
        continuation.yield(.stateChanged(.recording))
        return behaviour.meetingID
    }

    func finish() async -> MeetingSessionOutcome {
        counts.withLock { $0.finishes += 1 }
        ChangeSignal.fireFromAnywhere()
        if behaviour.hangsOnFinish {
            try? await Task.sleep(for: .seconds(3600))
            return behaviour.outcome
        }
        await behaviour.finishLatch?.wait()
        if behaviour.omitsFinished {
            if behaviour.endsStreamWithoutFinished { continuation.finish() }
            return behaviour.outcome
        }
        continuation.yield(.stateChanged(.finishing))
        continuation.yield(.stateChanged(.processing))
        continuation.yield(.finished(behaviour.outcome))
        continuation.finish()
        return behaviour.outcome
    }
}

/// Waits until `condition` holds, woken by the HUD, the phase and the sessions instead of polling. A real-time
/// timeout only keeps a broken test from hanging.
@MainActor
func eventually(
    _ message: Comment = "condition", timeout: Duration = .seconds(60), _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    let timer = Task { @MainActor in
        try? await Task.sleep(for: timeout)
        ChangeSignal.shared.fire()
    }
    while !condition(), ContinuousClock.now < deadline {
        await ChangeSignal.shared.wait()
    }
    timer.cancel()
    #expect(condition(), message)
}

/// The controller with fakes for everything it touches. Nothing real is captured, shown or stored.
@MainActor
final class ControllerRig {
    let harness: MeetingsHarness
    let library: MeetingsLibrary
    let hud = RecordingHUD()
    let authorizer: FakeAuthorizer
    let clock = ManualClock()
    let activity = MeetingActivity()
    var lookup = SpeechModelLookup.ready(modelID: "parakeet-ultra", folder: URL(filePath: "/tmp/lintel-test-model"))
    var behaviour = ScriptedSession.Behaviour()
    private(set) var sessions: [ScriptedSession] = []
    private(set) var requests: [MeetingSessionRequest] = []
    private(set) var openedURLs: [URL] = []
    private(set) var settingsOpened = 0
    private(set) var changes = Shared(0)
    private(set) var controller: MeetingController!
    private var markers = 0

    var session: ScriptedSession? { sessions.last }

    init(
        settings: [String: SettingValue] = [:], access: MicrophoneAccess = .granted,
        keychainError: KeychainError? = nil,
        shutdownTimeout: Duration = .seconds(5), observer: (any MeetingRecordingObserver)? = nil
    ) throws {
        harness = try MeetingsHarness(settings: settings)
        library = harness.library()
        authorizer = FakeAuthorizer(access)
        harness.keychain.failReads(with: keychainError)
        library.open()
        let changes = changes
        controller = MeetingController(
            .init(
                library: library, settings: harness.meetingsSettings, authorizer: authorizer, activity: activity,
                speechModel: { [unowned self] in self.lookup },
                makeSession: { [unowned self] request in
                    let session = ScriptedSession(self.behaviour)
                    self.sessions.append(session)
                    self.requests.append(request)
                    return session
                }, hud: hud, clock: clock, openSettings: { [unowned self] in self.settingsOpened += 1 },
                openURL: { [unowned self] url in self.openedURLs.append(url) },
                changed: { changes.update { $0 += 1 } }, shutdownTimeout: shutdownTimeout,
                stateChanged: { ChangeSignal.shared.fire() }, recordingObserver: observer))
    }

    /// Starts and waits until the recording runs.
    func startRecording() async {
        controller.start()
        await eventually("recording") { controller.phase == .recording }
    }

    /// Sends a marker event and waits until the controller has shown it: everything the session sent before is
    /// handled by then (one ordered stream).
    func drainEvents(through session: ScriptedSession? = nil) async {
        markers += 1
        let marker = 100_000 + markers
        let target = session ?? self.session
        target?.send(.elapsed(seconds: marker))
        await eventually("the marker event") { hud.lastRecording?.elapsedSeconds == marker }
    }

    /// Advances the clock and waits until `firing` controller timers have run out because of it.
    func advance(by duration: Duration, firing: Int) async {
        let before = controller.watcherFirings
        await eventually("the timers are waiting") { clock.sleepers >= firing }
        clock.advance(by: duration)
        await eventually("\(firing) timer(s) fire") { controller.watcherFirings >= before + firing }
    }
}
