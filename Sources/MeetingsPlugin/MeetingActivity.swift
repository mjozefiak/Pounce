import Foundation
import Observation
import PounceSpeech

/// Whether a meeting is being recorded or processed right now. The session owner (step 1.10) calls
/// `begin()` when a session starts and `end()` when it is over; Settings reads `isActive` to keep the models
/// a session uses from being removed under it.
@MainActor @Observable
final class MeetingActivity {
    private(set) var sessions = 0

    var isActive: Bool { sessions > 0 }

    func begin() { sessions += 1 }

    func end() { sessions = max(0, sessions - 1) }
}

/// Answers "is this model in use right now?" for the model cards: a meeting session or a background
/// "Finish" holds the diarization model, and any speech lease (dictation included, the lease is shared)
/// holds the speech model of its key.
struct MeetingsModelUsage: Sendable {
    /// `true` when removing `package` now would pull it out from under a user.
    let isInUse: @MainActor @Sendable (ModelPackage) async -> Bool

    static func live(
        activity: MeetingActivity, isProcessing: @escaping @MainActor @Sendable () -> Bool,
        leases: SpeechEngineLease = .shared
    ) -> MeetingsModelUsage {
        MeetingsModelUsage { package in
            if activity.isActive || isProcessing() { return true }
            guard await leases.activeLeases > 0 else { return false }
            // Only the resident model is held; another model's files are free to go.
            return await leases.residentKey?.modelID == package.id
        }
    }
}
