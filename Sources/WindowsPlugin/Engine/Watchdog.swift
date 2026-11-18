import Foundation

/// Counts frame changes and trips when the engine keeps changing more than `limit` of them per second for
/// `sustain` seconds (a fight with an app, a loop). Pure: time arrives as an argument.
struct Watchdog: Sendable {
    let limit: Int
    let sustain: Double
    private var stamps: [Double] = []
    private var overSince: Double?

    /// The engine's limit: frame changes per second.
    static let defaultLimit = 60

    init(limit: Int = Watchdog.defaultLimit, sustain: Double = 2) {
        self.limit = limit
        self.sustain = sustain
    }

    /// Records one frame change at `now`; true when the engine must freeze.
    mutating func record(now: Double) -> Bool {
        stamps.append(now)
        stamps.removeAll { $0 < now - 1 }
        if stamps.count > limit {
            let since = overSince ?? now
            overSince = since
            return now - since >= sustain
        }
        overSince = nil
        return false
    }

    mutating func reset() {
        stamps = []
        overSince = nil
    }
}
