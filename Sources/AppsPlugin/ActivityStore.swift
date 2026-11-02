import Foundation
import PounceCore
import PouncePersistence
import Synchronization
import os

/// How often one app was used, as stored in `activity.json` (app suggestions spec, Data Model).
struct ActivityEntry: Codable, Hashable, Sendable {
    /// The frecency as of `lastUsedAt`.
    var frecency: Double
    /// Unix seconds of the last use; never in the future.
    var lastUsedAt: Double
    var useCount: Int

    /// The frecency decayed to `now` with the given half-life.
    func decayedFrecency(at now: Date, halfLife: TimeInterval) -> Double {
        frecency * pow(2, -max(0, now.timeIntervalSince1970 - lastUsedAt) / halfLife)
    }

    /// Adds one use at `date` (Data Model: `f' = f·2^(−(T−t)/h) + 2^(−(T−d)/h)`, `T = max(t, d)`). The
    /// result does not depend on the order of the uses, so live uses and the Spotlight seed merge alike.
    mutating func addUse(at date: Double, halfLife: TimeInterval) {
        let latest = max(lastUsedAt, date)
        frecency =
            frecency * pow(2, -(latest - lastUsedAt) / halfLife) + pow(2, -(latest - date) / halfLife)
        lastUsedAt = latest
        useCount += 1
    }

    /// The entry of an app used once at `date`.
    static func firstUse(at date: Double) -> ActivityEntry {
        ActivityEntry(frecency: 1, lastUsedAt: date, useCount: 1)
    }
}

/// An immutable copy of the store, read by suggestions without touching the disk.
struct ActivitySnapshot: Hashable, Sendable {
    var apps: [String: ActivityEntry] = [:]
    /// ISO 8601 date of the finished seed, `"skipped"`, `"cleared"`, or `nil` before the seed.
    var seededAt: String?
    /// The file was written by a newer version: nothing is recorded, written or suggested.
    var isReadOnly = false

    static let empty = ActivitySnapshot()
}

/// Owner of `Plugins/apps/activity.json`: the app activity behind suggestions.
///
/// The file is read once by `load()`; afterwards the state lives in memory and every change publishes a
/// new `snapshot`. Writes are deferred (`saveDelay` after the last change) and flushed by `close()`,
/// always through `AtomicFile` (0600). Entries without a use in `retention` are pruned on load and on
/// every write. A corrupt file is moved to one `activity.json.corrupt` copy; a file from a newer
/// version makes the store read-only and is never touched. Errors are logged without bundle IDs.
actor ActivityStore {
    static let fileName = "activity.json"
    static let corruptFileName = "activity.json.corrupt"
    static let version = 1
    static let retention: TimeInterval = 90 * 24 * 60 * 60
    static let saveDelay: Duration = .seconds(30)
    /// `seededAt` when Spotlight is off.
    static let seedSkipped = "skipped"
    /// `seededAt` when the user cleared the data before the seed ran.
    static let seedCleared = "cleared"

    nonisolated let fileURL: URL
    nonisolated var corruptURL: URL {
        fileURL.deletingLastPathComponent().appending(path: Self.corruptFileName)
    }
    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>
    private let logger: Logger
    private let halfLife: TimeInterval
    private let published = Mutex(ActivitySnapshot.empty)
    private var state = ActivitySnapshot.empty
    private var isDirty = false
    private var saveTask: Task<Void, Never>?

    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock(),
        logger: Logger = Logger(subsystem: "app.pounce", category: "apps"),
        halfLife: TimeInterval = Ranker.frecencyHalfLife
    ) {
        self.fileURL = directory.appending(path: Self.fileName)
        self.now = now
        self.clock = clock
        self.logger = logger
        self.halfLife = halfLife
    }

    /// The current state, without waiting for the actor.
    nonisolated var snapshot: ActivitySnapshot { published.withLock { $0 } }

    var isReadOnly: Bool { state.isReadOnly }

    // MARK: Loading

    /// Reads the file. A missing file starts empty, a corrupt one is set aside, a newer one makes the
    /// store read-only.
    func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("Cannot read activity.json: \(String(describing: error), privacy: .private)")
            }
            replace(.empty)
            return
        }
        switch Self.decode(data) {
        case .current(let file):
            var loaded = ActivitySnapshot(apps: file.apps, seededAt: file.seededAt)
            let before = loaded.apps.count
            Self.prune(&loaded.apps, now: now())
            replace(loaded)
            if loaded.apps.count != before {
                markChanged()
            }
        case .newer:
            logger.notice("activity.json comes from a newer version; app suggestions are read-only")
            replace(ActivitySnapshot(isReadOnly: true))
        case .corrupt:
            logger.error("activity.json is corrupt; starting with empty app activity")
            setAsideCorruptFile()
            replace(.empty)
        }
    }

    enum Decoded {
        case current(FileContents)
        case newer
        case corrupt
    }

    struct FileContents: Codable {
        var version: Int
        var seededAt: String?
        var apps: [String: ActivityEntry]
    }

    private struct VersionOnly: Decodable {
        var version: Int
    }

    static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionOnly.self, from: data), header.version >= 1 else {
            return .corrupt
        }
        guard header.version == version else { return .newer }
        guard let file = try? decoder.decode(FileContents.self, from: data) else { return .corrupt }
        return .current(file)
    }

    private func setAsideCorruptFile() {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: corruptURL.path) {
                try fileManager.removeItem(at: corruptURL)
            }
            try fileManager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            logger.error("Cannot set aside activity.json: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Changes

    /// Records one use of an app.
    func recordUse(of bundleID: String, at date: Date) {
        guard !state.isReadOnly else { return }
        let time = min(date, now()).timeIntervalSince1970
        if var entry = state.apps[bundleID] {
            entry.addUse(at: time, halfLife: halfLife)
            state.apps[bundleID] = entry
        } else {
            state.apps[bundleID] = .firstUse(at: time)
        }
        publish()
        markChanged()
    }

    /// Merges the Spotlight seed in one step and sets `seededAt`. Ignored once a seed finished, was
    /// skipped or the data was cleared, so a seed that races "Clear App Activity" never restores it.
    func merge(seed: [String: [Date]], seededAt: String) {
        guard !state.isReadOnly, state.seededAt == nil else { return }
        let latest = now().timeIntervalSince1970
        for (bundleID, dates) in seed {
            for date in dates {
                let time = min(date.timeIntervalSince1970, latest)
                if var entry = state.apps[bundleID] {
                    entry.addUse(at: time, halfLife: halfLife)
                    state.apps[bundleID] = entry
                } else {
                    state.apps[bundleID] = .firstUse(at: time)
                }
            }
        }
        Self.prune(&state.apps, now: now())
        state.seededAt = seededAt
        publish()
        markChanged()
    }

    /// Spotlight is off: the seed will never run.
    func markSeedSkipped() {
        guard !state.isReadOnly, state.seededAt == nil else { return }
        state.seededAt = Self.seedSkipped
        publish()
        markChanged()
    }

    /// "Clear App Activity": forgets every app and keeps the seed from coming back.
    func removeAll() {
        guard !state.isReadOnly else { return }
        state.apps = [:]
        if state.seededAt == nil {
            state.seededAt = Self.seedCleared
        }
        publish()
        markChanged()
    }

    /// Writes pending changes now and stops the deferred write.
    func close() {
        saveTask?.cancel()
        saveTask = nil
        if isDirty {
            save()
        }
    }

    // MARK: Writing

    private func markChanged() {
        guard !state.isReadOnly else { return }
        isDirty = true
        saveTask?.cancel()
        let clock = clock
        saveTask = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.saveDelay)
            } catch {
                return
            }
            await self?.deferredSave()
        }
    }

    private func deferredSave() {
        saveTask = nil
        if isDirty {
            save()
        }
    }

    /// Writes the file. On failure the state stays in memory and the next change tries again.
    private func save() {
        guard !state.isReadOnly else { return }
        Self.prune(&state.apps, now: now())
        publish()
        let file = FileContents(version: Self.version, seededAt: state.seededAt, apps: state.apps)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(file)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try AtomicFile.write(data, to: fileURL)
            isDirty = false
        } catch {
            logger.error("Cannot write activity.json: \(String(describing: error), privacy: .private)")
        }
    }

    // MARK: Helpers

    static func prune(_ apps: inout [String: ActivityEntry], now: Date) {
        let cutoff = now.timeIntervalSince1970 - retention
        apps = apps.filter { $0.value.lastUsedAt >= cutoff }
    }

    private func replace(_ snapshot: ActivitySnapshot) {
        state = snapshot
        isDirty = false
        publish()
    }

    private func publish() {
        let state = state
        published.withLock { $0 = state }
    }

    var hasPendingWrite: Bool { isDirty }
}
