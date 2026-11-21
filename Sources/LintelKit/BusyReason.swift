/// Why a plugin cannot be interrupted right now. The shell reads it (`LintelPlugin.busyReason`) to hold back the
/// relaunch of an update; it never shows it. Added with the update flow; protected contract, additive only.
public enum BusyReason: Sendable, Equatable {
    /// Audio is being captured now (a recording or a dictation in progress).
    case recording
    /// Work is in progress that a quit would lose or would have to redo (transcribing, formatting, writing notes).
    case processing
}
