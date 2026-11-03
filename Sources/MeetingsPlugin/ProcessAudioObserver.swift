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
    /// Removes every listener. Safe to call more than once; ends `events`.
    let stop: @Sendable () -> Void
}

/// Watches which processes use an audio input. `CoreAudioProcessObserver` is the real one (event-driven, no
/// polling); tests use a scripted fake and never reach Core Audio, so they cannot show a prompt or read real
/// processes.
protocol ProcessAudioObserver: Sendable {
    /// Starts listening. The first events describe processes that already use an input. Throws
    /// `.unavailable` when the API cannot be used on this Mac.
    func start() throws(ProcessAudioError) -> ProcessAudioSubscription
}
