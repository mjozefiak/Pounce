import Foundation

/// Why system audio could not be captured. The record command falls back to the microphone track alone on
/// any of these (spec step 1.4, ADR 0007 item 4).
enum SystemAudioError: Error, Equatable, Sendable {
    /// `plugins.meetings.systemAudio` is off.
    case disabled
    /// The OS refused the tap (consent not given). Usually a denial shows up as silence instead, which the
    /// self-test detects.
    case permissionDenied
    /// A Core Audio call failed (`OSStatus`) or there is no output device.
    case tapUnavailable(Int32)
    /// The tap delivers a format the converter cannot handle.
    case unsupportedFormat
    /// The self-test's tap delivered no buffer at all (neither signal nor zeros).
    case noData
    /// The self-test's tone player did not finish in time.
    case timedOut
    /// The self-test's tone player failed (`NSError` code, 0 when unknown).
    case tonePlayerFailed(Int32)
}

/// One buffer from the tap: interleaved `Float32` frames and the host time of the first frame.
struct TapBuffer: Sendable, Equatable {
    var samples: [Float]
    var channels: Int
    var sampleRate: Double
    /// `mach_absolute_time` ticks of the first frame (the IO proc's input time).
    var hostTime: UInt64
    /// False when the IO proc's time stamp did not have `kAudioTimeStampHostTimeValid`; the source then
    /// stamps the buffer from its own clock.
    var hostTimeValid = true
}

/// A running tap; stopping is idempotent and releases the tap, the aggregate device and the IO proc.
protocol ProcessTapSession: Sendable {
    func stop()
}

/// An observation of the default output device (a Bluetooth headset connecting, say).
protocol OutputChangeObservation: Sendable {
    func cancel()
}

/// Everything Core Audio that system capture needs. The real implementation
/// (`CoreAudioProcessTapBackend`) is compiled but exercised only by hand; tests use a scripted fake.
protocol ProcessTapBackend: Sendable {
    /// Creates a tap of all processes (except Lintel's own when `excludingOwnProcess`), an aggregate device
    /// around it and an IO proc that calls `onBuffer` (on a worker queue, never on the audio thread itself).
    func startTap(
        excludingOwnProcess: Bool, onBuffer: @escaping @Sendable (TapBuffer) -> Void
    ) throws(SystemAudioError) -> any ProcessTapSession

    /// Calls `handler` whenever the default output device changes. Throws when the listener cannot be
    /// installed, so the caller can report that device changes will go unnoticed.
    func observeOutputDeviceChanges(
        _ handler: @escaping @Sendable () -> Void
    ) throws(SystemAudioError) -> any OutputChangeObservation
}
