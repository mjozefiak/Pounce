import Foundation
import os

/// The retention policy: entries last used more than `days` ago, and everything beyond the `maximumCount`
/// most recently used, are deleted together with their blob files.
struct RetentionPolicy: Equatable, Sendable {
    static let `default` = RetentionPolicy(days: 30, maximumCount: 1000)
    /// Choices offered in Settings → Clipboard History.
    static let dayChoices = [1, 7, 30, 90]
    static let countChoices = [100, 250, 500, 1000]

    var days: Int
    var maximumCount: Int

    func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(max(1, days)) * 24 * 60 * 60)
    }
}

/// Applies retention at activation and every hour, and sweeps orphaned blob files once a day (spec step
/// 2.6). Ranking needs no cleanup: `ranking.sqlite` holds nothing from the clipboard.
@MainActor
final class RetentionJob {
    static let interval: Duration = .seconds(60 * 60)
    static let sweepInterval: TimeInterval = 24 * 60 * 60

    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let logger: Logger
    private var task: Task<Void, Never>?
    private var lastSweep: Date?

    init(clock: any Clock<Duration>, now: @escaping () -> Date = { Date() }, logger: Logger) {
        self.clock = clock
        self.now = now
        self.logger = logger
    }

    var isRunning: Bool { task != nil }

    /// Runs once now and then every hour, until `stop()`.
    func start(
        store: @escaping @MainActor () -> ClipStore?, policy: @escaping @MainActor () -> RetentionPolicy,
        changed: @escaping @MainActor () -> Void
    ) {
        stop()
        let clock = clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let store = store(), await self.run(store: store, policy: policy()) {
                    changed()
                }
                do {
                    try await clock.sleep(for: Self.interval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One pass in the background. Returns whether entries were deleted.
    @discardableResult
    func run(store: ClipStore, policy: RetentionPolicy) async -> Bool {
        let now = now()
        let sweeps = lastSweep.map { now.timeIntervalSince($0) >= Self.sweepInterval } ?? true
        if sweeps {
            lastSweep = now
        }
        let logger = logger
        return await Task.detached(priority: .utility) {
            do {
                let deleted = try store.applyRetention(
                    cutoff: policy.cutoff(now: now), maximumCount: policy.maximumCount)
                if sweeps {
                    let orphans = try store.sweepOrphans()
                    if orphans > 0 {
                        logger.info("Removed \(orphans, privacy: .public) orphaned blob files")
                    }
                }
                if deleted > 0 {
                    logger.info("Retention deleted \(deleted, privacy: .public) clipboard entries")
                }
                return deleted > 0
            } catch {
                logger.error("Retention failed: \(String(describing: error), privacy: .private)")
                return false
            }
        }.value
    }
}
