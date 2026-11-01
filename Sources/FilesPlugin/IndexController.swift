import Foundation
import Synchronization
import os

/// What the index is doing, for the panel's progress bar and the settings pane.
struct IndexStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Not started: the Full Disk Access step has not been seen yet, or the plugin is off.
        case waiting
        /// Reading the saved snapshot.
        case loading
        /// A full scan is running; results grow as it goes.
        case scanning
        /// Up to date and following FSEvents.
        case ready
    }

    var phase: Phase
    var count: Int

    static let waiting = IndexStatus(phase: .waiting, count: 0)
}

/// Runs the index (spec steps 3.4 and 3.5): loads the snapshot or scans, then follows FSEvents and saves
/// the snapshot. All work happens in `run()`, one job after another, so a rescan and an event batch never
/// interleave; events that arrive during a scan wait in the watcher's buffer and are applied afterwards
/// (reconciling is idempotent, so applying a change the scan already saw is harmless).
final class IndexController: Sendable {
    struct Configuration: Sendable {
        var plan: IndexPlan
        /// `Plugins/files/`.
        var storageDirectory: URL
        var workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        /// The snapshot is saved this often while there are unsaved changes.
        var saveInterval: Duration = .seconds(600)
        /// During a full scan, a partial snapshot is saved every this many entries.
        var partialSaveEvery = 100_000
        /// During a full scan, searches see new entries this often.
        var publishInterval: Duration = .milliseconds(400)
        var eventLatency: TimeInterval = 0.5
    }

    private struct Progress {
        var lastEventID: UInt64 = 0
        var dirty = false
        var fullScans = 0
        /// During a full scan: the entry count of the next partial save.
        var nextPartialSave: Int?
    }

    let index: FileIndex
    let configuration: Configuration
    private let onStatus: @Sendable (IndexStatus) -> Void
    private let onChange: @Sendable () -> Void
    private let logger: Logger
    private let progress = Mutex(Progress())
    private let signposter = OSSignposter(subsystem: "app.pounce", category: "files")
    /// Canonical root paths as FSEvents reports them, mapped to the roots (`RescanPlanner.aliases`).
    private let rootAliases: [String: String]

    init(
        index: FileIndex,
        configuration: Configuration,
        logger: Logger,
        onStatus: @escaping @Sendable (IndexStatus) -> Void,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.index = index
        self.configuration = configuration
        self.logger = logger
        self.onStatus = onStatus
        self.onChange = onChange
        rootAliases = RescanPlanner.aliases(of: configuration.plan.roots)
    }

    /// How many full scans ran (tests: a valid snapshot must not cause one).
    var fullScanCount: Int { progress.withLock { $0.fullScans } }

    private var plan: IndexPlan { configuration.plan }
    private var scanner: BulkScanner {
        BulkScanner(rules: plan.rules, workerCount: configuration.workerCount)
    }

    // MARK: Run

    /// Loads or scans, then follows changes until the task is cancelled. Saves on the way out.
    func run() async {
        onStatus(IndexStatus(phase: .loading, count: index.snapshot.liveCount))
        let loaded = await load()
        let watcher = FileEventWatcher(
            paths: plan.roots, sinceWhen: loaded.replayFrom, latency: configuration.eventLatency)
        let startID = FileEventWatcher.currentEventID
        if !watcher.start() {
            logger.error("FSEvents refused to watch the index roots")
        }
        defer { watcher.stop() }

        if loaded.needsFullScan {
            await fullScan()
            guard !Task.isCancelled else { return }
            progress.withLock { $0.lastEventID = max($0.lastEventID, startID) }
            await save(complete: true)
        }
        onStatus(IndexStatus(phase: .ready, count: await index.count))

        let (wakeups, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Events buffered during the scan are handled right away.
        wake.yield()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in watcher.wakeups { wake.yield() }
            }
            group.addTask { [configuration] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: configuration.saveInterval)
                    wake.yield()
                }
            }
            var lastSave = ContinuousClock.now
            for await _ in wakeups {
                await handle(watcher.drain())
                if progress.withLock({ $0.dirty }), ContinuousClock.now - lastSave >= configuration.saveInterval {
                    await save(complete: true)
                    lastSave = .now
                }
            }
            group.cancelAll()
        }
        if progress.withLock({ $0.dirty }) {
            await save(complete: true)
        }
    }

    // MARK: Loading

    private struct Loaded {
        var needsFullScan: Bool
        /// The event id to replay FSEvents from, or `nil` for "since now".
        var replayFrom: UInt64?
    }

    /// Restores the snapshot when it matches the plan and the volumes. A partial snapshot is restored for
    /// immediate results, but a full scan follows. Anything else deletes the file and scans.
    private func load() async -> Loaded {
        let state = signposter.beginInterval("snapshot load")
        defer { signposter.endInterval("snapshot load", state) }
        let snapshot: IndexSnapshot
        do {
            snapshot = try IndexSnapshot.load(from: configuration.storageDirectory)
        } catch {
            if error != .missing {
                logger.notice("Index snapshot unusable (\(String(describing: error), privacy: .public)); rescanning")
                IndexSnapshot.delete(in: configuration.storageDirectory)
            }
            return Loaded(needsFullScan: true, replayFrom: nil)
        }
        guard snapshot.fingerprint == plan.fingerprint, Self.devicesMatch(snapshot.roots, plan: plan) else {
            logger.notice("Index snapshot does not match the roots or volumes; rescanning")
            IndexSnapshot.delete(in: configuration.storageDirectory)
            return Loaded(needsFullScan: true, replayFrom: nil)
        }
        await index.replace(with: snapshot.store)
        onChange()
        guard snapshot.complete else {
            logger.notice("Index snapshot is partial; rescanning")
            return Loaded(needsFullScan: true, replayFrom: nil)
        }
        progress.withLock { $0.lastEventID = snapshot.lastEventID }
        logger.info("Loaded \(snapshot.store.liveCount, privacy: .public) index entries")
        return Loaded(needsFullScan: false, replayFrom: snapshot.lastEventID)
    }

    /// Every root of the plan that exists has the same FSEvents device UUID as when it was saved.
    static func devicesMatch(_ saved: [IndexSnapshot.Root], plan: IndexPlan) -> Bool {
        let byPath = Dictionary(saved.map { ($0.path, $0.deviceUUID) }, uniquingKeysWith: { first, _ in first })
        for root in plan.roots where BulkScanner.entry(at: root, followsLink: true) != nil {
            guard let uuid = byPath[root], uuid == (FileEventWatcher.deviceUUID(of: root) ?? "") else { return false }
        }
        return true
    }

    // MARK: Scanning

    /// Scans every root from scratch, publishing as it goes and saving a partial snapshot every
    /// `partialSaveEvery` entries.
    private func fullScan() async {
        let state = signposter.beginInterval("full scan")
        defer { signposter.endInterval("full scan", state) }
        progress.withLock { $0.fullScans += 1 }
        let started = ContinuousClock.now
        let roots = await index.setRoots(plan.roots) { path in
            BulkScanner.entry(at: path, followsLink: true).map { ($0.kind, $0.modified) }
        }
        onStatus(IndexStatus(phase: .scanning, count: 0))
        progress.withLock { $0.nextPartialSave = configuration.partialSaveEvery }
        defer { progress.withLock { $0.nextPartialSave = nil } }
        for path in plan.roots {
            guard let node = roots[path] else { continue }
            await scan(node: node, path: path)
            if Task.isCancelled { return }
        }
        await index.publish()
        onChange()
        let elapsed = ContinuousClock.now - started
        let count = await index.count
        logger.info(
            "Scanned \(count, privacy: .public) entries in \(elapsed.components.seconds, privacy: .public) s")
    }

    /// Replaces everything below the folder at `node` with a fresh scan of `path`.
    private func scan(node: Int32, path: String) async {
        let token = await index.beginScan(at: node)
        let (batches, sink) = AsyncStream<[ScannedDirectory]>.makeStream()
        let cancelled = Mutex(false)
        let scanner = scanner
        let followsLink = plan.roots.contains(path)
        let worker = Self.runBlocking {
            scanner.scan(path, followsLink: followsLink, isCancelled: { cancelled.withLock { $0 } }) { sink.yield($0) }
            sink.finish()
        }
        await withTaskCancellationHandler {
            var lastPublish = ContinuousClock.now
            for await batch in batches {
                let count = await index.absorb(batch, scan: token)
                if ContinuousClock.now - lastPublish >= configuration.publishInterval {
                    await index.publish()
                    onChange()
                    lastPublish = .now
                    if progress.withLock({ $0.nextPartialSave != nil }) {
                        onStatus(IndexStatus(phase: .scanning, count: count))
                    }
                }
                await savePartialIfDue(count)
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        await worker.value
        await index.endScan(token)
    }

    /// Runs blocking work (the scanner waits on its worker threads) on a GCD queue, so it never holds a
    /// Swift concurrency thread; awaiting the task suspends until the work ends.
    private static func runBlocking(_ work: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    work()
                    done.resume()
                }
            }
        }
    }

    /// During a full scan, saves an incomplete snapshot each time the count passes the next multiple of
    /// `partialSaveEvery`, so an interrupted first scan still gives results after a restart.
    private func savePartialIfDue(_ count: Int) async {
        let every = configuration.partialSaveEvery
        let due = progress.withLock { progress -> Bool in
            guard let next = progress.nextPartialSave, count >= next else { return false }
            progress.nextPartialSave = (count / every + 1) * every
            return true
        }
        if due {
            await save(complete: false)
        }
    }

    // MARK: Events

    private func handle(_ drained: (events: [FileEvent], overflowed: Bool)) async {
        guard !drained.events.isEmpty || drained.overflowed else { return }
        var plan = RescanPlanner.plan(
            drained.events, roots: self.plan.roots, rules: self.plan.rules, aliases: rootAliases)
        if drained.overflowed {
            plan.everything = true
            plan = RescanPlanner.coalesced(plan, roots: self.plan.roots)
        }
        let state = signposter.beginInterval("apply events")
        defer { signposter.endInterval("apply events", state) }

        if plan.everything {
            logger.notice("FSEvents dropped events; rescanning every root")
            await fullScan()
        } else {
            for root in plan.roots.sorted() {
                await rescan(root)
            }
            for subtree in plan.subtrees.sorted() {
                await rescan(subtree)
            }
            for folder in plan.folders.sorted() {
                await reconcile(folder)
            }
        }
        await index.publish()
        progress.withLock {
            $0.lastEventID = max($0.lastEventID, plan.lastEventID)
            $0.dirty = true
        }
        if !plan.isEmpty {
            onChange()
        }
        onStatus(IndexStatus(phase: .ready, count: await index.count))
    }

    /// Scans a root or subtree again; a root that is gone is removed, a new one is added.
    private func rescan(_ path: String) async {
        if plan.roots.contains(path) {
            let roots = await index.setRoots(plan.roots) { root in
                BulkScanner.entry(at: root, followsLink: true).map { ($0.kind, $0.modified) }
            }
            guard let node = roots[path] else {
                await index.remove(path: path)
                return
            }
            await scan(node: node, path: path)
            return
        }
        let found = await index.locate(path)
        if let node = found.node, found.kind == .directory, BulkScanner.entry(at: path)?.kind == .directory {
            await scan(node: node, path: path)
        } else {
            await reconcile(PathText.parent(path))
        }
    }

    /// Compares one folder with a fresh listing, walking up while the folder itself is missing on disk or
    /// in the index.
    private func reconcile(_ folder: String) async {
        var target = folder
        for _ in 0..<64 {
            let found = await index.locate(target)
            guard found.deepest != nil else { return }
            guard let node = found.node else {
                // Not indexed yet: the deepest indexed ancestor gains the missing folders.
                guard found.deepestKind == .directory else { return }
                target = found.deepestPath
                continue
            }
            guard found.kind == .directory else { return }
            guard let listing = scanner.list(target, followsLink: plan.roots.contains(target)) else {
                // Gone (or unreadable): its parent's listing drops it.
                if BulkScanner.entry(at: target) == nil, found.isRoot == false {
                    target = PathText.parent(target)
                    continue
                }
                return
            }
            for folder in await index.reconcile(node: node, path: target, listing: listing) {
                await scan(node: folder.node, path: folder.path)
            }
            return
        }
    }

    // MARK: Saving

    /// Saves the current index (atomically, mode 0600).
    func save(complete: Bool) async {
        let store = await index.currentStore()
        let lastEventID = progress.withLock { $0.lastEventID }
        let roots = plan.roots.map {
            IndexSnapshot.Root(path: $0, deviceUUID: FileEventWatcher.deviceUUID(of: $0) ?? "")
        }
        let snapshot = IndexSnapshot(
            complete: complete, lastEventID: lastEventID, fingerprint: plan.fingerprint, roots: roots, store: store)
        let directory = configuration.storageDirectory
        let logger = logger
        let state = signposter.beginInterval("snapshot save")
        await Task.detached(priority: .utility) {
            do {
                try snapshot.save(in: directory)
            } catch {
                logger.error("Cannot save the index snapshot: \(String(describing: error), privacy: .public)")
            }
        }.value
        signposter.endInterval("snapshot save", state)
        if complete {
            progress.withLock { $0.dirty = false }
        }
    }
}

extension FileIndex {
    struct Location: Sendable {
        var node: Int32?
        var kind: EntryKind?
        var isRoot: Bool
        var deepest: Int32?
        var deepestPath: String
        var deepestKind: EntryKind?
    }

    /// Where a path is in the live index (not only the published snapshot).
    func locate(_ path: String) -> Location {
        let store = current
        let found = store.locate(path)
        let isRoot = found.node.map { store.flags[Int($0)].contains(.root) } ?? false
        return Location(
            node: found.node,
            kind: found.node.map(store.kind),
            isRoot: isRoot,
            deepest: found.deepest,
            deepestPath: found.deepest.map(store.path) ?? "",
            deepestKind: found.deepest.map(store.kind)
        )
    }
}
