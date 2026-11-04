import Foundation
import Synchronization

/// Plays a short signal through the default output. The real one (`AVAudioEngineTonePlayer`) is announced by
/// the "Play test signal" button; there are no hidden sounds.
protocol TonePlayer: Sendable {
    /// Plays a tone of about `duration` seconds and returns when it ended.
    func play(duration: TimeInterval) async throws
}

/// The only way to check the system-audio permission, which has no read API (spec "Research"): tap
/// everything including Lintel, play a signal of our own and see whether the tap hears it.
struct SystemAudioSelfTest: Sendable {
    enum Verdict: Equatable, Sendable {
        /// The tap heard the signal: "works".
        case works
        /// The tap delivered buffers, but only zeros: "no audio - check the permission".
        case silent
        /// The tap or the player could not start, the tap delivered no buffer at all (`.noData`) or the
        /// player did not finish in time (`.timedOut`).
        case unavailable(SystemAudioError)
    }

    /// Peak amplitude below which a buffer counts as zeros.
    static let silenceFloor: Float = 1e-4

    private struct Heard {
        var buffers = 0
        var peak: Float = 0
    }

    let backend: any ProcessTapBackend
    let player: any TonePlayer
    var toneDuration: TimeInterval = 0.3
    /// How long the tap keeps listening after the tone ended (buffers arrive a little late).
    var settle: Duration = .milliseconds(150)
    var sleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The longest the player may take; the test then gives up on it so it can never hang.
    var playbackTimeout: Duration = .seconds(3)
    /// The clock of `playbackTimeout`, injectable like `sleeper`.
    var timeoutSleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func run() async -> Verdict {
        let heard = Mutex(Heard())
        let session: any ProcessTapSession
        do {
            session = try backend.startTap(excludingOwnProcess: false) { buffer in
                let peak = buffer.samples.reduce(Float(0)) { abs($1).isFinite && abs($1) > $0 ? abs($1) : $0 }
                heard.withLock {
                    $0.buffers += 1
                    $0.peak = max($0.peak, peak)
                }
            }
        } catch {
            return .unavailable(error)
        }
        defer { session.stop() }
        do {
            try await playBounded()
        } catch let error as SystemAudioError {
            return .unavailable(error)
        } catch {
            return .unavailable(.tonePlayerFailed(Int32(clamping: (error as NSError).code)))
        }
        await sleeper(settle)
        let result = heard.withLock { $0 }
        // No buffer at all means the tap never ran; buffers of zeros are what a denied permission delivers.
        if result.buffers == 0 { return .unavailable(.noData) }
        return result.peak > Self.silenceFloor ? .works : .silent
    }

    /// Plays the tone but stops waiting after `playbackTimeout`, even when the player ignores cancellation.
    private func playBounded() async throws {
        let player = self.player
        let duration = toneDuration
        let limit = playbackTimeout
        let timeoutSleeper = self.timeoutSleeper
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let race = PlaybackRace(continuation)
            race.add(
                Task {
                    do {
                        try await player.play(duration: duration)
                        race.finish(.success(()))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
            race.add(
                Task {
                    await timeoutSleeper(limit)
                    guard !Task.isCancelled else { return }
                    race.finish(.failure(SystemAudioError.timedOut))
                })
        }
    }
}

/// Resumes its continuation exactly once, with whichever of the player and the timer ends first, and cancels
/// the other.
private final class PlaybackRace: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state: Mutex<State>

    init(_ continuation: CheckedContinuation<Void, any Error>) {
        state = Mutex(State(continuation: continuation))
    }

    func add(_ task: Task<Void, Never>) {
        let finished = state.withLock { state -> Bool in
            state.tasks.append(task)
            return state.continuation == nil
        }
        if finished { task.cancel() }
    }

    func finish(_ result: Result<Void, any Error>) {
        let (continuation, tasks) = state.withLock {
            state -> (CheckedContinuation<Void, any Error>?, [Task<Void, Never>]) in
            defer { state.continuation = nil }
            return (state.continuation, state.tasks)
        }
        guard let continuation else { return }
        continuation.resume(with: result)
        for task in tasks { task.cancel() }
    }
}
