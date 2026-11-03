import Foundation

/// One change of "this audio process uses (or stopped using) an input device" (spec: Wykrywanie spotkań).
/// This is all the detector ever learns about another app: which process, its bundle ID and a flag. No audio,
/// no window titles, no contents.
struct ProcessAudioEvent: Equatable, Sendable {
    /// The Core Audio process object (not the Unix pid); stable while the process lives.
    var processObjectID: UInt32
    /// `nil` when Core Audio does not know it (and always `nil` for a process that is gone).
    var bundleID: String?
    var isRunningInput: Bool
}

enum ProcessAudioError: Error, Equatable, Sendable {
    /// The Core Audio process objects or their properties are missing or refuse to answer. The detector then
    /// reports `.unavailable` and meeting suggestions switch themselves off (spec: negative result of 3.1).
    case unavailable(Int32)
}

/// A running observation: events in the order Core Audio reported them, and the way to stop.
struct ProcessAudioSubscription: Sendable {
    let events: AsyncStream<ProcessAudioEvent>
    /// Removes every listener. Safe to call more than once; ends `events`. Never blocks the caller.
    let stop: @Sendable () -> Void
    /// Resolves when the listeners are installed (off the caller's thread): `nil` when they are, the error
    /// when the API cannot be used (the events then end). The default has nothing to wait for.
    var installed: @Sendable () async -> ProcessAudioError? = { nil }
    /// Whether any process has ever answered the "uses an input" question. `nil` when the observer cannot
    /// tell; the detector then does not check.
    var hasAnswered: (@Sendable () -> Bool)?
}

/// Watches which processes use an audio input. `CoreAudioProcessObserver` is the real one (event-driven, no
/// polling); tests use a scripted fake and never reach Core Audio, so they cannot show a prompt or read real
/// processes.
protocol ProcessAudioObserver: Sendable {
    /// Starts listening and returns at once. The first events describe processes that already use an input.
    /// Throws `.unavailable` when the API cannot be used on this Mac and that is known without waiting;
    /// otherwise a failure comes through `ProcessAudioSubscription.installed`.
    func start() throws(ProcessAudioError) -> ProcessAudioSubscription
}
