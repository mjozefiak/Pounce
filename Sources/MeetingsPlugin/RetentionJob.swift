import Foundation
import os

/// Applies the retention policy at activation and every hour: meetings older than `plugins.meetings
/// .retentionDays` (0 keeps everything) are deleted with their spool folders, expired spools of interrupted
/// meetings go (`orphanAudioDays`), and a `VACUUM` runs at most once a day. Transcripts never reach a log.
@MainActor
final class RetentionJob {
    static let interval: Duration = .seconds(60 * 60)
    static let vacuumInterval: TimeInterval = 24 * 60 * 60

    struct Policy: Equatable, Sendable {
        /// 0 means unlimited.
        var retentionDays: Int
        var orphanAudioDays: Int

        func cutoff(now: Date) -> Date? {
            retentionDays > 0 ? now.addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60) : nil
        }

        func orphanCutoff(now: Date) -> Date {
            now.addingTimeInterval(-Double(max(1, orphanAudioDays)) * 24 * 60 * 60)
        }
    }

    private let clock: any Clock<Duration>
    private let now: () -> Date
    private let spool: any SpoolMaintenance
    private let logger: Logger
    private var task: Task<Void, Never>?
    private(set) var lastVacuum: Date?

    init(
        clock: any Clock<Duration>, now: @escaping () -> Date = { Date() },
        spool: any SpoolMaintenance = NoSpoolMaintenance(), logger: Logger
    ) {
        self.clock = clock
        self.now = now
        self.spool = spool
        self.logger = logger
    }

    var isRunning: Bool { task != nil }

    /// Runs once now and then every hour, until `stop()`. `hourly` runs on each pass too, even while the
    /// library is unavailable (the plugin purges expired reset archives there).
    func start(
        store: @escaping @MainActor () -> MeetingsStore?, policy: @escaping @MainActor () -> Policy,
        hourly: @escaping @MainActor () -> Void = {}, changed: @escaping @MainActor () -> Void
    ) {
        stop()
        let clock = clock
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                hourly()
                if let store = store(), await self.run(store: store, policy: policy()) > 0 {
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

    /// One pass in the background. Returns how many meetings were deleted.
    @discardableResult
    func run(store: MeetingsStore, policy: Policy) async -> Int {
        let now = now()
        let vacuums = lastVacuum.map { now.timeIntervalSince($0) >= Self.vacuumInterval } ?? true
        let spool = spool
        let logger = logger
        let outcome = await Task.detached(priority: .utility) { () -> (deleted: Int, vacuumed: Bool) in
            do {
                var uuids: [String] = []
                if let cutoff = policy.cutoff(now: now) {
                    uuids = try store.applyRetention(cutoff: cutoff)
                    spool.removeSpools(forMeetings: uuids)
                }
                // Only interrupted meetings age out; the sweep never sees a recording or processing one.
                let candidates = Set(try store.incompleteSpoolUUIDs())
                let orphans = spool.removeSpools(olderThan: policy.orphanCutoff(now: now), among: candidates)
                try store.markAudioDeleted(uuids: orphans)
                if !uuids.isEmpty || !orphans.isEmpty {
                    logger.info(
                        "Retention deleted \(uuids.count, privacy: .public) meetings and \(orphans.count, privacy: .public) old spools"
                    )
                }
                var vacuumed = false
                if vacuums, !uuids.isEmpty {
                    try store.vacuum()
                    vacuumed = true
                }
                return (uuids.count, vacuumed)
            } catch MeetingsStoreError.closed {
                // The plugin deactivated while the pass ran: a quiet cancel.
                return (0, false)
            } catch {
                logger.error("Retention failed: \(String(describing: type(of: error)), privacy: .public)")
                return (0, false)
            }
        }.value
        if outcome.vacuumed {
            lastVacuum = now
        }
        return outcome.deleted
    }
}
