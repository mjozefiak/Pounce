import Foundation
import LintelKit

/// Counts the time apps spend in front (app suggestions spec, Q2).
///
/// After an app becomes active, the first check runs at `max(now + 5 s, lastUsedAt + 10 min)`; while the
/// app stays in front, another check follows every 10 minutes. A check records a use when the app is
/// still frontmost, its last use is at least 10 minutes old, and the user touched the keyboard, mouse or
/// trackpad in the last 10 minutes. A port that cannot tell the idle time (`nil`) gets the first use only
/// and no heartbeat. A new activation cancels the pending checks. Apps without a bundle identifier and
/// Lintel itself are ignored; the port already filters out non-regular apps.
@MainActor
final class ActivityTracker {
    /// How long an app must stay in front before it counts.
    static let threshold: TimeInterval = 5
    /// The heartbeat, and the minimum gap between two uses of one app.
    static let interval: TimeInterval = 10 * 60
    /// A use counts only when the user gave input within this time.
    static let idleLimit: TimeInterval = 10 * 60
    /// Clock jitter allowed when comparing the gap with `interval`.
    static let tolerance: TimeInterval = 1

    private let workspace: any WorkspaceClient
    private let store: ActivityStore
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let ownBundleIdentifier: String?
    private var listener: Task<Void, Never>?
    private var check: Task<Void, Never>?

    init(
        workspace: any WorkspaceClient,
        store: ActivityStore,
        clock: any Clock<Duration>,
        now: @escaping @Sendable () -> Date = { Date() },
        ownBundleIdentifier: String?
    ) {
        self.workspace = workspace
        self.store = store
        self.clock = clock
        self.now = now
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    var isRunning: Bool { listener != nil }

    /// Starts listening for activations; also checks the app already in front.
    func start() {
        guard listener == nil else { return }
        let activations = workspace.applicationActivations()
        listener = Task { [weak self] in
            for await application in activations {
                self?.activated(application)
            }
        }
        // The activation stream carries regular apps only; the frontmost app gets the same filter through
        // the running regular apps, so an agent or accessory in front at start is not tracked either.
        if let current = workspace.frontmostApplication, let bundleID = current.bundleIdentifier,
            workspace.runningApplicationBundleIDs.contains(bundleID)
        {
            activated(current)
        }
    }

    /// Stops listening and cancels the pending check. Returns the cancelled check, so a caller can wait
    /// until a use it may still be recording has landed.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        listener?.cancel()
        listener = nil
        let cancelled = check
        check?.cancel()
        check = nil
        return cancelled
    }

    /// A new frontmost app: cancels the checks of the previous one and schedules this one's.
    func activated(_ application: RunningApplication) {
        check?.cancel()
        check = nil
        guard let bundleID = application.bundleIdentifier, !bundleID.isEmpty, bundleID != ownBundleIdentifier
        else { return }
        check = Task { [weak self] in
            await self?.track(bundleID)
        }
    }

    /// Waits for the current checks to end (tests).
    func waitForChecks() async {
        await check?.value
    }

    /// Runs the checks of one activation until the app leaves the front or the task is cancelled.
    func track(_ bundleID: String) async {
        let start = now()
        // A last use after `start` (the clock moved back) cannot be trusted and is ignored, so it never
        // pushes the first check out; the store clamps it to now when it records the next use.
        let lastUsed = store.snapshot.apps[bundleID]
            .map { Date(timeIntervalSince1970: $0.lastUsedAt) }
            .flatMap { $0 <= start ? $0 : nil }
        var due = max(
            start.addingTimeInterval(Self.threshold),
            lastUsed?.addingTimeInterval(Self.interval) ?? .distantPast
        )
        var isFirstCheck = true
        while !Task.isCancelled {
            let delay = max(0, due.timeIntervalSince(now()))
            do {
                try await clock.sleep(for: .milliseconds(Int64((delay * 1000).rounded())))
            } catch {
                return
            }
            guard !Task.isCancelled, workspace.frontmostApplication?.bundleIdentifier == bundleID else { return }
            let idle = workspace.secondsSinceLastUserInput
            let checkTime = now()
            let previous = store.snapshot.apps[bundleID]?.lastUsedAt
            // Likewise a last use after the check.
            let gapIsLongEnough =
                previous.map {
                    $0 > checkTime.timeIntervalSince1970
                        || checkTime.timeIntervalSince1970 - $0 >= Self.interval - Self.tolerance
                } ?? true
            if let idle {
                if idle < Self.idleLimit, gapIsLongEnough {
                    await store.recordUse(of: bundleID, at: checkTime)
                }
            } else {
                // Without idle information only the first check may count, and there is no heartbeat.
                if isFirstCheck, gapIsLongEnough {
                    await store.recordUse(of: bundleID, at: checkTime)
                }
                return
            }
            isFirstCheck = false
            due = checkTime.addingTimeInterval(Self.interval)
        }
    }
}
