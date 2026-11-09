import Darwin
import Foundation
import Synchronization

/// Samples this process's `phys_footprint` (what Activity Monitor calls Memory) on a background task and
/// reports the peak, not the final value.
final class FootprintSampler: Sendable {
    private struct State {
        var peak: UInt64 = 0
        var task: Task<Void, Never>?
    }

    private let interval: Duration
    private let state = Mutex(State())

    init(interval: Duration = .milliseconds(250)) { self.interval = interval }

    static func currentBytes() -> UInt64 {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0)
            }
        }
        return status == 0 ? info.ri_phys_footprint : 0
    }

    private func record() {
        let now = Self.currentBytes()
        state.withLock { $0.peak = max($0.peak, now) }
    }

    func start() {
        record()
        let interval = interval
        let task = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                record()
            }
        }
        state.withLock { $0.task = task }
    }

    /// Stops sampling and returns the peak in megabytes (MiB).
    func stop() async -> Double {
        let task = state.withLock { state -> Task<Void, Never>? in
            defer { state.task = nil }
            return state.task
        }
        task?.cancel()
        await task?.value
        record()
        return Double(state.withLock { $0.peak }) / 1_048_576
    }
}
