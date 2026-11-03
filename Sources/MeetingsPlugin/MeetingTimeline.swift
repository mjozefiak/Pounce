import Darwin
import Foundation

/// A monotonic host-time clock (`mach_absolute_time`). Both audio tracks stamp their buffers from this one
/// clock, so they can be aligned to a common start (spec step 1.4).
protocol HostClock: Sendable {
    /// The current host time in mach ticks.
    func now() -> UInt64
}

struct SystemHostClock: HostClock {
    func now() -> UInt64 { mach_absolute_time() }
}

/// Mach ticks to nanoseconds (`numer / denom`). The identity for tests.
struct HostTimeConverter: Sendable, Equatable {
    let numer: UInt64
    let denom: UInt64

    init(numer: UInt64, denom: UInt64) {
        self.numer = numer
        self.denom = max(1, denom)
    }

    /// Ticks are nanoseconds.
    static let identity = HostTimeConverter(numer: 1, denom: 1)

    static var system: HostTimeConverter {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return HostTimeConverter(numer: UInt64(info.numer), denom: UInt64(info.denom))
    }

    func nanoseconds(_ ticks: UInt64) -> UInt64 {
        // 128-bit intermediate: ticks * numer can overflow 64 bits after long uptimes.
        let (high, low) = ticks.multipliedFullWidth(by: numer)
        return denom.dividingFullWidth((high, low)).quotient
    }
}

/// Maps host-time stamped buffers of both tracks onto milliseconds since one common start.
struct TimelineAlignment: Sendable, Equatable {
    /// Host time (ticks) of the recording's start.
    let originHostTime: UInt64
    let converter: HostTimeConverter

    init(originHostTime: UInt64, converter: HostTimeConverter) {
        self.originHostTime = originHostTime
        self.converter = converter
    }

    /// The common start of tracks that began at the given host times: the earliest one.
    init?(commonStartOf hostTimes: [UInt64], converter: HostTimeConverter) {
        guard let first = hostTimes.min() else { return nil }
        self.init(originHostTime: first, converter: converter)
    }

    /// Milliseconds since the common start; negative for a stamp before it.
    func milliseconds(forHostTime hostTime: UInt64) -> Int64 {
        nanosecondsSinceOrigin(hostTime) / 1_000_000
    }

    /// Samples at `sampleRate` between the common start and `hostTime` (rounded, never negative): the
    /// silence a track that began later gets in front, so its sample 0 lands on the shared timeline.
    func sampleOffset(forHostTime hostTime: UInt64, sampleRate: Int) -> Int {
        let nanos = nanosecondsSinceOrigin(hostTime)
        guard nanos > 0 else { return 0 }
        return Int((Double(nanos) * Double(sampleRate) / 1e9).rounded())
    }

    private func nanosecondsSinceOrigin(_ hostTime: UInt64) -> Int64 {
        if hostTime >= originHostTime {
            return Int64(clamping: converter.nanoseconds(hostTime - originHostTime))
        }
        return -Int64(clamping: converter.nanoseconds(originHostTime - hostTime))
    }
}
