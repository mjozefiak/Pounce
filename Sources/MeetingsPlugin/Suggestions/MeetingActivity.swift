import Foundation
import LintelSpeech
import Observation

/// Whether a meeting is being recorded or processed right now. The session owner (step 1.10) calls
/// `begin()` when a session starts and `end()` when it is over; Settings reads `isActive` to keep the models
/// a session uses from being removed under it, and Clear Library reads it to keep its orphan sweep away from
/// a spool folder that exists before its row.
///
/// Contract for the session owner: `begin()` comes before anything is created (the spool folder, the row, a
/// lease) and `end()` only after the meeting reached its final status and released its leases. That includes
/// the whole "Dokończ"/finish of a meeting (replay, speaker assignment, closing), not just the recording.
/// A start also checks `isRemovingModel` and refuses (the model card is deleting a model right now).
@MainActor @Observable
final class MeetingActivity {
    private(set) var sessions = 0
    private(set) var modelRemovals = 0

    var isActive: Bool { sessions > 0 }

    /// A model card is removing a model; a session must not start until it is done.
    var isRemovingModel: Bool { modelRemovals > 0 }

    func begin() { sessions += 1 }

    func end() { sessions = max(0, sessions - 1) }

    func beginModelRemoval() { modelRemovals += 1 }

    func endModelRemoval() { modelRemovals = max(0, modelRemovals - 1) }
}

/// Answers "is this model in use right now?" for the model cards: a meeting session or a background
/// "Finish" holds the diarization model, and any speech lease (dictation included, the lease is shared)
/// holds the speech model of its key.
struct MeetingsModelUsage: Sendable {
    /// `true` when removing `package` now would pull it out from under a user.
    let isInUse: @MainActor @Sendable (ModelPackage) async -> Bool
    /// Reserves the right to remove a model for as long as the returned closure has not been called.
    let reserveRemoval: @MainActor @Sendable () -> @MainActor @Sendable () -> Void

    init(
        isInUse: @escaping @MainActor @Sendable (ModelPackage) async -> Bool,
        reserveRemoval: @escaping @MainActor @Sendable () -> @MainActor @Sendable () -> Void = { {} }
    ) {
        self.isInUse = isInUse
        self.reserveRemoval = reserveRemoval
    }

    static func live(
        activity: MeetingActivity, isProcessing: @escaping @MainActor @Sendable () -> Bool,
        leases: SpeechEngineLease = .shared
    ) -> MeetingsModelUsage {
        MeetingsModelUsage(
            isInUse: { package in
                if activity.isActive || isProcessing() { return true }
                guard await leases.activeLeases > 0 else { return false }
                // Only the resident model is held; another model's files are free to go.
                return await leases.residentKey?.modelID == package.id
            },
            reserveRemoval: {
                activity.beginModelRemoval()
                return { activity.endModelRemoval() }
            })
    }
}
