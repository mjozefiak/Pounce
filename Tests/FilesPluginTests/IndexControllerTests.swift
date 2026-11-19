import CoreServices
import Foundation
import LintelCore
import Synchronization
import Testing
import os

@testable import FilesPlugin

/// The phases an `IndexController` reported, in order.
final class PhaseLog: Sendable {
    private let log = Mutex<[IndexStatus.Phase]>([])
    var values: [IndexStatus.Phase] { log.withLock { $0 } }
    func append(_ phase: IndexStatus.Phase) { log.withLock { $0.append(phase) } }
}

/// Runs an `IndexController` over a fixture folder (spec 3.4: FSEvents and the snapshot). It keeps what the
/// controller reports, so a test waits for the next event instead of polling the clock.
final class ControllerRun: Sendable {
    let index: FileIndex
    let controller: IndexController
    /// Signals after every `onChange` (a batch of changes was applied and published).
    let changes: ChangeCounter
    /// Signals after every `onStatus`.
    let statusEvents: ChangeCounter
    private let phases: PhaseLog
    private let task: Task<Void, Never>

    init(root: String, storage: URL, index: FileIndex = FileIndex(), exclusions: [String] = []) {
        let rules = IgnoreRules.make(home: root, userExclusions: exclusions, includesHidden: false)
        let plan = RootPlanner.plan(
            configuredRoots: [root], home: root, fullDiskAccess: true, addedProtected: [],
            includesICloudDrive: false, rules: rules)
        var configuration = IndexController.Configuration(plan: plan, storageDirectory: storage)
        configuration.eventLatency = 0.05
        configuration.workerCount = 2
        let changes = ChangeCounter()
        let statusEvents = ChangeCounter()
        let phases = PhaseLog()
        let controller = IndexController(
            index: index, configuration: configuration,
            logger: Logger(subsystem: "com.lintelapp.tests", category: "files"),
            onStatus: { status in
                phases.append(status.phase)
                statusEvents.signal()
            },
            onChange: { changes.signal() })
        self.index = index
        self.controller = controller
        self.changes = changes
        self.statusEvents = statusEvents
        self.phases = phases
        task = Task.detached { await controller.run() }
    }

    func stop() async {
        task.cancel()
        await task.value
    }

    func contains(_ name: String) -> Bool {
        let store = index.snapshot
        return (0..<store.flags.count).contains { store.isLive(Int32($0)) && store.name(Int32($0)) == name }
    }

    /// Every phase the controller reported, in order.
    var reportedPhases: [IndexStatus.Phase] { phases.values }

    /// The controller finished loading or scanning and saved the snapshot (`IndexStatus.Phase.ready`).
    /// A non-empty index is not enough: a partial snapshot or the first scanned folder fills it while the
    /// scan still runs, and stopping then skips the complete save.
    @MainActor
    func ready(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        await awaitEvents(statusEvents, sourceLocation: sourceLocation) { self.reportedPhases.contains(.ready) }
    }

    /// The index holds the answer once the controller applied the changes: waits for the next published
    /// batch, then checks again.
    @MainActor
    func eventuallyIndexed(
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async -> Bool {
        await awaitEvents(changes, sourceLocation: sourceLocation) { condition() }
    }
}

@MainActor
@Suite("Index controller", .serialized)
struct IndexControllerTests {
    let directory: TemporaryDirectory
    var root: String { directory.sub("root") }
    var storage: URL { directory.url.appending(path: "storage", directoryHint: .isDirectory) }

    init() throws {
        directory = try TemporaryDirectory()
        try directory.make(["root/alpha.txt", "root/folder/beta.txt", "storage/"])
    }

    /// The watcher is started before the first scan (`IndexController.run`), so a change made once the
    /// controller is ready is seen. How fast FSEvents delivers it is a budget, measured in `Benchmarks.swift`.
    @Test func createRenameAndDeleteShowUpInTheIndex() async throws {
        let run = ControllerRun(root: root, storage: storage)
        #expect(await run.ready())
        #expect(run.contains("beta.txt"))

        try directory.make(["root/folder/gamma-new.txt"])
        #expect(await run.eventuallyIndexed { run.contains("gamma-new.txt") })

        try FileManager.default.moveItem(
            atPath: directory.sub("root/folder/gamma-new.txt"), toPath: directory.sub("root/delta-moved.txt"))
        #expect(await run.eventuallyIndexed { run.contains("delta-moved.txt") && !run.contains("gamma-new.txt") })

        try FileManager.default.removeItem(atPath: directory.sub("root/folder"))
        #expect(await run.eventuallyIndexed { !run.contains("beta.txt") && !run.contains("folder") })

        try directory.make(["root/new-folder/inner/epsilon.txt"])
        #expect(await run.eventuallyIndexed { run.contains("epsilon.txt") })
        await run.stop()
    }

    @Test func excludedFoldersStayOutAfterChanges() async throws {
        let run = ControllerRun(root: root, storage: storage)
        #expect(await run.ready())
        try directory.make(["root/node_modules/pkg/index.js", "root/visible-marker.txt"])
        #expect(await run.eventuallyIndexed { run.contains("visible-marker.txt") })
        #expect(!run.contains("index.js"))
        await run.stop()
    }

    @Test func restartLoadsTheSnapshotAndCatchesUpWithoutAFullScan() async throws {
        let first = ControllerRun(root: root, storage: storage)
        #expect(await first.ready())
        #expect(first.controller.fullScanCount == 1)
        await first.stop()
        #expect(FileManager.default.fileExists(atPath: IndexSnapshot.url(in: storage).path))
        let savedEventID = try IndexSnapshot.load(from: storage).lastEventID

        // Changed while Lintel was not running.
        try directory.make(["root/folder/while-away.txt"])
        try FileManager.default.removeItem(atPath: directory.sub("root/alpha.txt"))
        // The second run replays FSEvents history. Wait until the system's history holds both changes, which
        // is what the replay reads, instead of guessing how long the daemon takes to write it.
        #expect(
            await historyHolds(
                root: root, since: savedEventID,
                changes: [
                    ("/root/folder/while-away.txt", kFSEventStreamEventFlagItemCreated),
                    ("/root/alpha.txt", kFSEventStreamEventFlagItemRemoved),
                ]))

        let second = ControllerRun(root: root, storage: storage)
        #expect(await second.ready())
        #expect(await second.eventuallyIndexed { second.contains("while-away.txt") && !second.contains("alpha.txt") })
        #expect(second.controller.fullScanCount == 0)
        await second.stop()
    }

    @Test func snapshotFromAnotherVolumeIsDiscarded() async throws {
        let first = ControllerRun(root: root, storage: storage)
        #expect(await first.ready())
        await first.stop()
        var snapshot = try IndexSnapshot.load(from: storage)
        snapshot.roots = snapshot.roots.map { IndexSnapshot.Root(path: $0.path, deviceUUID: "00000000-OTHER") }
        try snapshot.save(in: storage)

        let second = ControllerRun(root: root, storage: storage)
        // `ready` comes after the full scan, which counts itself first.
        #expect(await second.ready())
        #expect(second.controller.fullScanCount == 1)
        await second.stop()
    }

    @Test func partialSnapshotIsShownThenRescanned() async throws {
        let first = ControllerRun(root: root, storage: storage)
        #expect(await first.ready())
        await first.stop()
        var snapshot = try IndexSnapshot.load(from: storage)
        snapshot.complete = false
        try snapshot.save(in: storage)

        let second = ControllerRun(root: root, storage: storage)
        #expect(await second.ready())
        #expect(second.controller.fullScanCount == 1)
        await second.stop()
        #expect(try IndexSnapshot.load(from: storage).complete)
    }

    @Test func damagedSnapshotIsReplaced() async throws {
        try Data("PNCEIDX\0garbage".utf8).write(to: IndexSnapshot.url(in: storage))
        let run = ControllerRun(root: root, storage: storage)
        #expect(await run.ready())
        #expect(run.controller.fullScanCount == 1)
        await run.stop()
        #expect(try IndexSnapshot.load(from: storage).store.liveCount == run.index.snapshot.liveCount)
    }
}

/// Waits until an FSEvents stream started at `since` reports every change in `changes` (a path suffix and the event flag) (FSEvents
/// reports `/private/var/…` where the fixture says `/var/…`), that is until the
/// history a restarted controller replays contains them. `false` after a 60 s hang guard.
@MainActor
func historyHolds(
    root: String, since: UInt64, changes: [(suffix: String, flag: Int)],
    sourceLocation: SourceLocation = #_sourceLocation
)
    async
    -> Bool
{
    let watcher = FileEventWatcher(paths: [root], sinceWhen: since, latency: 0.05)
    guard watcher.start() else {
        Issue.record("FSEvents refused to watch the fixture", sourceLocation: sourceLocation)
        return false
    }
    defer { watcher.stop() }
    let found = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var missing = changes
            for await _ in watcher.wakeups {
                for event in watcher.drain().events {
                    missing.removeAll { event.path.hasSuffix($0.suffix) && event.has($0.flag) }
                }
                if missing.isEmpty { return true }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(60))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    if !found, !Task.isCancelled {
        Issue.record("The FSEvents history never held the changes", sourceLocation: sourceLocation)
    }
    return found
}

@Suite("Index snapshot")
struct IndexSnapshotTests {
    private func sample() -> IndexSnapshot {
        var store = NameStore()
        let root = store.addRoot(path: "/fixture/root", kind: .directory, modified: 10)
        let folder = store.addChild("Zażółć Folder", kind: .directory, modified: 20, parent: root)
        _ = store.addChild("report.PDF", kind: .file, modified: 30, parent: folder)
        _ = store.addChild("Tool.app", kind: .package, modified: 40, parent: root)
        _ = store.addChild("link", kind: .symlink, modified: 50, parent: root)
        return IndexSnapshot(
            complete: true, lastEventID: 42, fingerprint: "abc",
            roots: [IndexSnapshot.Root(path: "/fixture/root", deviceUUID: "UUID-1")], store: store)
    }

    @Test func roundTripKeepsTheTree() throws {
        let original = sample()
        let decoded = try IndexSnapshot.decode(try original.encoded())
        #expect(decoded.complete)
        #expect(decoded.lastEventID == 42)
        #expect(decoded.fingerprint == "abc")
        #expect(decoded.roots == original.roots)
        #expect(decoded.store.liveCount == original.store.liveCount)
        let report = try #require(decoded.store.locate("/fixture/root/Zażółć Folder/report.PDF").node)
        #expect(decoded.store.kind(report) == .file)
        #expect(decoded.store.modified[Int(report)] == 30)
        decoded.store.withFoldedBytes(Int(report)) { #expect(Array($0) == Array("report.pdf".utf8)) }
        let tool = try #require(decoded.store.locate("/fixture/root/Tool.app").node)
        #expect(decoded.store.kind(tool) == .package)
    }

    @Test func removedNodesAreNotSaved() throws {
        var snapshot = sample()
        if let node = snapshot.store.locate("/fixture/root/Zażółć Folder").node {
            snapshot.store.remove(node)
        }
        let decoded = try IndexSnapshot.decode(try snapshot.encoded())
        #expect(decoded.store.liveCount == 2)  // roots are not counted
        #expect(decoded.store.locate("/fixture/root/Zażółć Folder/report.PDF").node == nil)
    }

    @Test func unknownVersionAndDamageAreReported() throws {
        var data = try sample().encoded()
        data[8] = 99
        #expect(throws: IndexSnapshot.LoadError.unknownVersion(99)) { try IndexSnapshot.decode(data) }
        #expect(throws: IndexSnapshot.LoadError.damaged) { try IndexSnapshot.decode(Data("nope".utf8)) }
        var truncated = try sample().encoded()
        truncated.removeLast(10)
        #expect(throws: IndexSnapshot.LoadError.damaged) { try IndexSnapshot.decode(truncated) }
    }

    @Test func savedFileIsPrivate() throws {
        let directory = try TemporaryDirectory()
        try sample().save(in: directory.url)
        let attributes = try FileManager.default.attributesOfItem(atPath: IndexSnapshot.url(in: directory.url).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(throws: IndexSnapshot.LoadError.missing) {
            IndexSnapshot.delete(in: directory.url)
            _ = try IndexSnapshot.load(from: directory.url)
        }
    }
}

@Suite("Rescan planner")
struct RescanPlannerTests {
    let rules = IgnoreRules.make(home: "/r", userExclusions: [], includesHidden: false)
    let roots = ["/r", "/Applications"]

    func event(_ path: String, _ flags: Int = kFSEventStreamEventFlagItemCreated, id: UInt64 = 1) -> FileEvent {
        FileEvent(path: path, flags: UInt32(flags), id: id)
    }

    @Test func changesBecomeTheirFolders() {
        let plan = RescanPlanner.plan(
            [event("/r/a/x.txt", id: 5), event("/r/a/y.txt", id: 7), event("/r/b/", id: 6), event("/elsewhere/z")],
            roots: roots, rules: rules)
        #expect(plan.folders == ["/r/a", "/r"])
        #expect(plan.lastEventID == 7)
        #expect(!plan.everything)
    }

    @Test func excludedPlacesAreIgnored() {
        let plan = RescanPlanner.plan(
            [event("/r/node_modules/pkg/i.js"), event("/r/Library/Caches/x")], roots: roots, rules: rules)
        #expect(plan.isEmpty)
    }

    @Test func mustScanSubDirsCoversFoldersBelowIt() {
        let plan = RescanPlanner.plan(
            [
                event("/r/a/b/c.txt"), event("/r/a", kFSEventStreamEventFlagMustScanSubDirs),
                event("/r/a/b", kFSEventStreamEventFlagMustScanSubDirs), event("/r/other/d.txt"),
            ], roots: roots, rules: rules)
        #expect(plan.subtrees == ["/r/a"])
        #expect(plan.folders == ["/r/other"])
    }

    @Test func droppedEventsRescanEverything() {
        for flag in [
            kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped,
            kFSEventStreamEventFlagEventIdsWrapped,
        ] {
            let plan = RescanPlanner.plan([event("/r/a/x"), event("/r", flag)], roots: roots, rules: rules)
            #expect(plan.everything)
            #expect(plan.roots == Set(roots))
            #expect(plan.folders.isEmpty)
        }
    }

    /// FSEvents reports `MustScanSubDirs` for an ancestor of the roots (`/`) when its history is incomplete.
    @Test func mustScanSubDirsAboveTheRootsRescansThem() {
        let plan = RescanPlanner.plan(
            [event("/", kFSEventStreamEventFlagMustScanSubDirs), event("/r/a/x")], roots: roots, rules: rules)
        #expect(plan.roots == Set(roots))
        #expect(plan.folders.isEmpty)
        #expect(plan.subtrees.isEmpty)
    }

    @Test func rootChangedRescansThatRoot() {
        let plan = RescanPlanner.plan(
            [event("/r", kFSEventStreamEventFlagRootChanged), event("/r/a/x")], roots: roots, rules: rules)
        #expect(plan.roots == ["/r"])
        #expect(plan.folders.isEmpty)
    }

    @Test func historyDoneIsNoted() {
        let plan = RescanPlanner.plan(
            [event("", kFSEventStreamEventFlagHistoryDone, id: 9)], roots: roots, rules: rules)
        #expect(plan.historyDone)
        #expect(plan.isEmpty)
        #expect(plan.lastEventID == 9)
    }
}

extension RescanPlannerTests {
    @Test func canonicalPathsMapBackToTheRoot() {
        let plan = RescanPlanner.plan(
            [event("/private/r/a/x.txt")], roots: roots, rules: rules, aliases: ["/private/r": "/r"])
        #expect(plan.folders == ["/r/a"])
        #expect(RescanPlanner.unaliased("/private/rx/a", aliases: ["/private/r": "/r"]) == "/private/rx/a")
    }

    @Test func theLongestAliasWins() {
        let aliases = ["/private/r": "/r", "/private/r/deep/inner": "/inner"]
        for _ in 0..<20 {
            #expect(RescanPlanner.unaliased("/private/r/deep/inner/x.txt", aliases: aliases) == "/inner/x.txt")
            #expect(RescanPlanner.unaliased("/private/r/deep/y.txt", aliases: aliases) == "/r/deep/y.txt")
        }
    }

    @Test func aliasesResolveSymlinkedRoots() throws {
        let directory = try TemporaryDirectory()
        try directory.make(["target/"])
        try FileManager.default.createSymbolicLink(
            atPath: directory.sub("link"), withDestinationPath: directory.sub("target"))
        let aliases = RescanPlanner.aliases(of: [directory.sub("link")])
        #expect(aliases.values.first == directory.sub("link"))
        #expect(aliases.keys.first?.hasSuffix("/target") == true)
    }
}

/// A root the user added as a symbolic link (for example `~/Dropbox`, which points into
/// `~/Library/CloudStorage`) is indexed through the link, and its changes arrive under the link's path.
@MainActor
@Suite("Symlinked root", .serialized)
struct SymlinkedRootTests {
    @Test func symlinkedRootIsIndexedAndFollowed() async throws {
        let directory = try TemporaryDirectory()
        try directory.make(["target/inside.txt", "target/sub/deep.txt", "storage/"])
        try FileManager.default.createSymbolicLink(
            atPath: directory.sub("link"), withDestinationPath: directory.sub("target"))
        let run = ControllerRun(
            root: directory.sub("link"), storage: directory.url.appending(path: "storage", directoryHint: .isDirectory))
        #expect(await run.ready())
        #expect(run.contains("inside.txt") && run.contains("deep.txt"))
        try Data("x".utf8).write(to: directory.url.appending(path: "target/sub/added.txt"))
        #expect(await run.eventuallyIndexed { run.contains("added.txt") })
        await run.stop()
    }
}
