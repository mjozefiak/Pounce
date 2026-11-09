import CoreGraphics
import Foundation
import LintelKit
import os

/// What one pass over the journal of parked windows achieved. Counts only: no titles, no bundle ids.
struct RecoveryReport: Equatable, Sendable {
    /// Windows put back at their home frame.
    var restored = 0
    /// Journal entries whose window is not on this native Space (or is closed); they stay in the journal and are
    /// tried again when the Space is shown.
    var onAnotherSpace = 0
    /// Windows the app did not move (hung, refused); they stay in the journal.
    var failed = 0
    /// The journal comes from a newer version (or cannot be read): entries cannot be cleared, so one pass per
    /// process is all there is, and it never counts as a launch with parked windows.
    var readOnly = false
    /// Accessibility is not trusted, so nothing was moved and everything stays in the journal.
    var needsAccessibility = false

    /// Entries that are still in the journal.
    var remaining: Int { onAnotherSpace + failed }
    /// Whether anything was to do or left.
    var isEmpty: Bool { restored == 0 && remaining == 0 && !needsAccessibility }
    var outcome: RecoveryOutcome { (remaining == 0 || readOnly) && !needsAccessibility ? .done : .deferred }
}

/// Puts the windows of the journal back (spec: Edge Cases, "Lintel crashes or is killed while windows are
/// parked"). It is the one routine behind `recoverAtLaunch`, the restore on disable and quit, *Restore all
/// windows*, the re-grant of Accessibility and the reconcile on a Space change.
///
/// A window is moved only when its pid, its window number and its process start time still match the journal
/// entry (`StateStore.validated`). An entry that does not match is dropped and never moved. Nothing is moved
/// without Accessibility; the journal is then kept untouched.
enum WindowRecovery {
    /// - Parameters:
    ///   - trusted: whether Accessibility is granted; without it nothing is moved.
    ///   - excluding: windows the running engine has parked itself; they are the engine's to restore.
    static func run(
        store: StateStore, client: any WindowClient, trusted: Bool, excluding: Set<WindowID> = [],
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "windows")
    ) async -> RecoveryReport {
        let entries: [HiddenEntry]
        do {
            entries = try await store.validated(processStart: { client.processStart(of: $0) })
        } catch {
            // The journal could not be cleaned (read-only file): still restore what matches.
            logger.error("Cannot drop stale journal entries")
            // The start time is still compared: a reused pid must never be moved.
            entries = await store.hidden.filter { entry in
                guard let live = client.processStart(of: entry.windowID.pid) else { return false }
                return abs(live - entry.processStart) <= StateStore.processStartTolerance
            }
        }
        return await restore(
            store: store, client: client, trusted: trusted, excluding: excluding, logger: logger, entries: entries)
    }

    private static func restore(
        store: StateStore, client: any WindowClient, trusted: Bool, excluding: Set<WindowID>, logger: Logger,
        entries all: [HiddenEntry]
    ) async -> RecoveryReport {
        var report = RecoveryReport()
        report.readOnly = await store.isReadOnly
        let entries = all.filter { !excluding.contains($0.windowID) }
        guard !entries.isEmpty else { return report }
        guard trusted else {
            report.needsAccessibility = true
            return report
        }
        let live = Set(await client.windows().map(\.id))
        let displays = await client.displays()
        var targets: [HiddenEntry] = []
        var responding: [Int32: Bool] = [:]
        for entry in entries {
            if live.contains(entry.windowID) {
                targets.append(entry)
                continue
            }
            // Not in the list: on another Space when its app answers, not reachable when it does not (a hung app
            // lists nothing either, and must not be reported as a window on another Space).
            let pid = entry.windowID.pid
            if responding[pid] == nil { responding[pid] = await client.isResponding(pid: pid) }
            if responding[pid] == true { report.onAnotherSpace += 1 } else { report.failed += 1 }
        }
        // In parallel across processes, in order within one.
        let results = await withTaskGroup(of: [(WindowID, Bool)].self) { group in
            for (_, part) in Dictionary(grouping: targets, by: \.windowID.pid) {
                group.addTask {
                    var done: [(WindowID, Bool)] = []
                    for entry in part {
                        let frame = FrameMath.restoredFrame(home: entry.homeFrame.rect, displays: displays)
                        do throws(WindowClientError) {
                            _ = try await client.setFrame(frame, for: entry.windowID)
                            done.append((entry.windowID, true))
                        } catch {
                            // A window that vanished meanwhile has nothing left to restore.
                            done.append((entry.windowID, error == .windowGone))
                        }
                    }
                    return done
                }
            }
            var all: [(WindowID, Bool)] = []
            for await part in group { all.append(contentsOf: part) }
            return all
        }
        var cleared = Set<WindowID>()
        for (id, ok) in results {
            if ok { cleared.insert(id) } else { report.failed += 1 }
        }
        report.restored = cleared.count
        if !cleared.isEmpty {
            do { try await store.removeHidden(cleared) } catch {
                logger.error("Cannot clear the journal after a restore")
            }
        }
        return report
    }
}
