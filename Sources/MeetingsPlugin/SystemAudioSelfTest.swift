import Foundation
import Synchronization

/// Plays a short signal through the default output. The real one (`AVAudioEngineTonePlayer`) is announced by
/// the "Play test signal" button; there are no hidden sounds.
protocol TonePlayer: Sendable {
    /// Plays a tone of about `duration` seconds and returns when it ended.
    func play(duration: TimeInterval) async throws
}

/// The only way to check the system-audio permission, which has no read API (spec "Research"): tap
/// everything including Pounce, play a signal of our own and see whether the tap hears it.
struct SystemAudioSelfTest: Sendable {
    enum Verdict: Equatable, Sendable {
        /// The tap heard the signal: "works".
        case works
        /// The tap delivered only zeros: "no audio - check the permission".
        case silent
        /// The tap or the player could not start.
        case unavailable(SystemAudioError)
    }

    /// Peak amplitude below which a buffer counts as zeros.
    static let silenceFloor: Float = 1e-4

    let backend: any ProcessTapBackend
    let player: any TonePlayer
    var toneDuration: TimeInterval = 0.3
    /// How long the tap keeps listening after the tone ended (buffers arrive a little late).
    var settle: Duration = .milliseconds(150)
    var sleeper: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    func run() async -> Verdict {
        let heard = Mutex(Float(0))
        let session: any ProcessTapSession
        do {
            session = try backend.startTap(excludingOwnProcess: false) { buffer in
                let peak = buffer.samples.reduce(Float(0)) { max($0, abs($1)) }
                heard.withLock { $0 = max($0, peak) }
            }
        } catch {
            return .unavailable(error)
        }
        defer { session.stop() }
        do {
            try await player.play(duration: toneDuration)
        } catch {
            return .unavailable(.tapUnavailable(-1))
        }
        await sleeper(settle)
        return heard.withLock { $0 } > Self.silenceFloor ? .works : .silent
    }
}
