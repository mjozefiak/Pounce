import Foundation
import Observation

/// The "Test system audio" flow shared by Settings, the setup step and Settings → Permissions.
///
/// macOS cannot report the System Audio Recording permission, so the test taps the output, plays a short
/// signal of Pounce's own and listens. Nothing happens until the user presses "Play test signal": starting
/// the flow only explains it, and the system's consent prompt (and the tone) come after that second click.
@MainActor @Observable
final class SystemAudioTestModel {
    enum State: Equatable {
        /// Nothing started.
        case idle
        /// Explained; waiting for "Play test signal".
        case awaitingConfirmation
        case running
        case finished(Outcome)
    }

    /// What the user is told, one text per `SystemAudioSelfTest.Verdict`.
    enum Outcome: Equatable {
        case works
        case silent
        case unavailable

        init(_ verdict: SystemAudioSelfTest.Verdict) {
            switch verdict {
            case .works: self = .works
            case .silent: self = .silent
            case .unavailable: self = .unavailable
            }
        }

        var message: String {
            switch self {
            case .works:
                String(
                    localized: "System audio works. Pounce heard its own test signal.",
                    comment: "Meetings: verdict of the system audio test when the signal was heard")
            case .silent:
                String(
                    localized:
                        "No audio came through. Check that Pounce is allowed under System Audio Recording, then test again.",
                    comment: "Meetings: verdict of the system audio test when only silence arrived")
            case .unavailable:
                String(
                    localized:
                        "System audio could not be tested. Check the output device and the permission, then try again.",
                    comment: "Meetings: verdict of the system audio test when the tap could not run")
            }
        }

        var symbolName: String {
            switch self {
            case .works: "checkmark.circle.fill"
            case .silent, .unavailable: "exclamationmark.triangle"
            }
        }
    }

    private(set) var state = State.idle

    /// Whether the last completed test heard the signal (this session only; nothing is stored).
    var isVerified: Bool { lastOutcome == .works }
    private(set) var lastOutcome: Outcome?

    @ObservationIgnored private let makeTest: @MainActor () -> SystemAudioSelfTest
    @ObservationIgnored private var task: Task<Void, Never>?

    /// True while a meeting is recorded or processed: the test taps the output, which a meeting already does.
    @ObservationIgnored private let blocked: @MainActor () -> Bool

    init(makeTest: @escaping @MainActor () -> SystemAudioSelfTest, blocked: @escaping @MainActor () -> Bool = { false })
    {
        self.makeTest = makeTest
        self.blocked = blocked
    }

    /// Whether the test cannot start now (a meeting is active). Reads observable state, so views update.
    var isBlocked: Bool { blocked() }

    /// "Test system audio": explains the test, plays nothing.
    func begin() {
        guard !isBlocked, state == .idle || isFinished else { return }
        state = .awaitingConfirmation
    }

    func cancel() {
        guard state == .awaitingConfirmation else { return }
        state = .idle
    }

    /// "Play test signal": the explicit step. Taps the output, plays the tone, listens, reports.
    func playSignal() {
        guard state == .awaitingConfirmation, !isBlocked else { return }
        state = .running
        let test = makeTest()
        task = Task { [weak self] in
            let outcome = Outcome(await test.run())
            self?.lastOutcome = outcome
            self?.state = .finished(outcome)
            self?.task = nil
        }
    }

    /// Resolves once a running test ended (tests).
    func waitForTest() async {
        await task?.value
    }

    private var isFinished: Bool {
        if case .finished = state { return true }
        return false
    }
}
