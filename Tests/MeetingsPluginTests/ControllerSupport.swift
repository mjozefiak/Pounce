import Foundation
import PounceKit
import PounceSpeech
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

    func show(_ state: MeetingHUDState) { states.append(state) }
    func hide() { hides += 1 }
}

/// A recording the test drives by hand: it sends events and decides how `start()` and `finish()` end.
final class ScriptedSession: RecordingSession {
    struct Behaviour {
        var startError: (any Error)?
        var meetingID: Int64 = 7
        var outcome = MeetingSessionOutcome(result: .ready, meetingID: 7)
        /// `finish()` waits forever (a shutdown that does not complete in time).
        var hangsOnFinish = false
    }

    let events: AsyncStream<MeetingSessionEvent>
    private let continuation: AsyncStream<MeetingSessionEvent>.Continuation
    private let state = Mutex(0)
    private let finishes = Mutex(0)
    private let behaviour: Behaviour

    init(_ behaviour: Behaviour = Behaviour()) {
        self.behaviour = behaviour
        (events, continuation) = AsyncStream.makeStream(of: MeetingSessionEvent.self, bufferingPolicy: .unbounded)
    }

    var startCount: Int { state.withLock { $0 } }
    var finishCount: Int { finishes.withLock { $0 } }

    func send(_ event: MeetingSessionEvent) { continuation.yield(event) }

    func start() async throws -> Int64 {
        state.withLock { $0 += 1 }
        if let error = behaviour.startError { throw error }
        continuation.yield(.stateChanged(.recording))
        return behaviour.meetingID
    }

    func finish() async -> MeetingSessionOutcome {
        finishes.withLock { $0 += 1 }
        if behaviour.hangsOnFinish {
            try? await Task.sleep(for: .seconds(3600))
            return behaviour.outcome
        }
        continuation.yield(.stateChanged(.finishing))
        continuation.yield(.stateChanged(.processing))
        continuation.yield(.finished(behaviour.outcome))
        continuation.finish()
        return behaviour.outcome
    }
}

/// Polls the main actor until `condition` holds or a few seconds pass.
@MainActor
func eventually(
    _ message: Comment = "condition", timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool
) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
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
    var lookup = SpeechModelLookup.ready(modelID: "parakeet-ultra", folder: URL(filePath: "/tmp/pounce-test-model"))
    var behaviour = ScriptedSession.Behaviour()
    private(set) var sessions: [ScriptedSession] = []
    private(set) var requests: [MeetingSessionRequest] = []
    private(set) var openedURLs: [URL] = []
    private(set) var settingsOpened = 0
    private(set) var changes = Shared(0)
    private(set) var controller: MeetingController!

    var session: ScriptedSession? { sessions.last }

    init(
        settings: [String: SettingValue] = [:], access: MicrophoneAccess = .granted,
        keychainError: KeychainError? = nil,
        shutdownTimeout: Duration = .seconds(5)
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
                changed: { changes.update { $0 += 1 } }, shutdownTimeout: shutdownTimeout))
    }

    /// Starts and waits until the recording runs.
    func startRecording() async {
        controller.start()
        await eventually("recording") { controller.phase == .recording }
    }

    /// Waits until the controller has handled everything the session sent so far.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
