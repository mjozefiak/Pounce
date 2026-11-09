import Foundation

/// The engine's one source of time: the injected `Clock` gives both the moment inputs carry (seconds since the
/// source was made) and the sleeps of the event tick, so a test that drives a virtual clock drives all of it.
struct TimeSource: Sendable {
    /// Seconds since this source was made.
    let now: @Sendable () -> Double
    let sleep: @Sendable (Duration) async throws -> Void

    init(_ clock: any Clock<Duration>) {
        self = Self.make(clock)
    }

    private static func make<C: Clock>(_ clock: C) -> TimeSource where C.Duration == Duration {
        let origin = clock.now
        return TimeSource(
            now: {
                let elapsed = origin.duration(to: clock.now)
                return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            },
            sleep: { try await clock.sleep(for: $0) })
    }

    private init(now: @escaping @Sendable () -> Double, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }
}
