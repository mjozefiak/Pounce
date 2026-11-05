import Foundation
import LintelKit

/// Collecting app activity for suggestions (app suggestions spec, Cykl życia).
extension AppsPlugin {
    /// Whether the tracker and the seed may run: suggestions on, the activity file not from a newer
    /// version, and (DEBUG QA mode) live activity not switched off.
    var isCollectionAllowed: Bool {
        guard context.settings.bool(AppsSettingsKey.suggestionsEnabled, default: true),
            !activity.snapshot.isReadOnly
        else { return false }
        #if DEBUG
        if !context.settings.bool(AppsSettingsKey.qaLiveActivity, default: true) {
            return false
        }
        #endif
        return true
    }

    /// Starts the tracker and schedules the seed, when allowed.
    func startCollectingIfAllowed() {
        guard isActive, isCollectionAllowed, tracker == nil else { return }
        let tracker = ActivityTracker(
            workspace: context.workspace,
            store: activity,
            clock: context.clock,
            now: now,
            ownBundleIdentifier: ownBundleIdentifier
        )
        self.tracker = tracker
        tracker.start()
        if ActivitySeeder(store: activity, reader: usageDatesReader, now: now).isNeeded {
            seedPending = true
            if hasRefreshed {
                startSeed(store.apps.map(\.record))
            }
        }
    }

    /// Stops the tracker and cancels the seed; the store stays open. Idempotent. Returns the cancelled
    /// tasks, which may still be finishing a write to the store.
    @discardableResult
    func stopCollecting() -> [Task<Void, Never>] {
        let check = tracker?.stop()
        tracker = nil
        let seed = seedTask
        cancelSeed()
        return [check, seed].compactMap(\.self)
    }

    /// The "Suggest Apps" toggle.
    func setSuggestionsEnabled(_ enabled: Bool) {
        if enabled {
            startCollectingIfAllowed()
        } else {
            stopCollecting()
        }
    }

    /// Cancels a running or pending seed; an interrupted seed writes nothing and runs on the next start.
    func cancelSeed() {
        seedTask?.cancel()
        seedTask = nil
        seedPending = false
    }

    /// A scan finished: the first one of this activation starts the pending seed.
    func appsRefreshed(_ apps: [AppRecord]) {
        hasRefreshed = true
        guard seedPending, tracker != nil else { return }
        startSeed(apps)
    }

    private func startSeed(_ apps: [AppRecord]) {
        seedPending = false
        let seeder = ActivitySeeder(store: activity, reader: usageDatesReader, now: now)
        let spotlight = context.settings.bool(AppsSettingsKey.spotlight, default: true)
        let logger = context.logger
        let resultsChanged = context.resultsChanged
        seedTask = Task.detached(priority: .utility) {
            do {
                try await seeder.run(apps: apps, spotlightEnabled: spotlight)
                if spotlight {
                    resultsChanged()
                }
            } catch is CancellationError {
                return
            } catch {
                logger.error("App activity seed failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Waits for the seed (tests).
    func waitForSeed() async {
        await seedTask?.value
    }

    #if DEBUG
    /// QA mode: writes `plugins.apps.qaActivity` (`bundleID=uses,…`) into an empty store, with now as the
    /// date, before the panel opens.
    func seedActivityForQA() async {
        guard let text = context.settings.string(AppsSettingsKey.qaActivity), activity.snapshot.apps.isEmpty
        else { return }
        let date = now()
        for (bundleID, uses) in Self.parseQAActivity(text) {
            for _ in 0..<uses {
                await activity.recordUse(of: bundleID, at: date)
            }
        }
    }

    /// `com.example.a=3,com.example.b` → `[("com.example.a", 3), ("com.example.b", 1)]`.
    static func parseQAActivity(_ text: String) -> [(String, Int)] {
        text.split(separator: ",").compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let bundleID = pieces.first, !bundleID.isEmpty else { return nil }
            let uses = pieces.count > 1 ? Int(pieces[1]) ?? 1 : 1
            return (bundleID, max(1, min(uses, 1000)))
        }
    }
    #endif
}
