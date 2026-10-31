import CoreServices
import Foundation
import PounceCore
import Testing
import os

@testable import FilesPlugin

/// Runs an `IndexController` over a fixture folder (spec 3.4: FSEvents and the snapshot).
final class ControllerRun: Sendable {
    let index: FileIndex
    let controller: IndexController
    private let task: Task<Void, Never>

    init(root: String, storage: URL, index: FileIndex = FileIndex(), exclusions: [String] = []) {
        let rules = IgnoreRules.make(home: root, userExclusions: exclusions, includesHidden: false)
        let plan = RootPlanner.plan(
            configuredRoots: [root], home: root, fullDiskAccess: true, addedProtected: [],
            includesICloudDrive: false, rules: rules)
        var configuration = IndexController.Configuration(plan: plan, storageDirectory: storage)
        configuration.eventLatency = 0.05
        configuration.workerCount = 2
        let controller = IndexController(
            index: index, configuration: configuration,
            logger: Logger(subsystem: "app.pounce.tests", category: "files"),
            onStatus: { _ in }, onChange: {})
        self.index = index
        self.controller = controller
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

    func ready() async -> Bool {
        await eventually { await self.index.count > 0 }
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

    @Test func createRenameAndDeleteShowUpWithinTwoSeconds() async throws {
        let run = ControllerRun(root: root, storage: storage)
        #expect(await run.ready())
        #expect(run.contains("beta.txt"))
        // Let the stream start before changing things.
        try await Task.sleep(for: .milliseconds(300))

        try directory.make(["root/folder/gamma-new.txt"])
        #expect(await eventually(timeout: .seconds(2)) { run.contains("gamma-new.txt") })

        try FileManager.default.moveItem(
            atPath: directory.sub("root/folder/gamma-new.txt"), toPath: directory.sub("root/delta-moved.txt"))
        #expect(
            await eventually(timeout: .seconds(2)) { run.contains("delta-moved.txt") && !run.contains("gamma-new.txt") }
        )

        try FileManager.default.removeItem(atPath: directory.sub("root/folder"))
        #expect(await eventually(timeout: .seconds(2)) { !run.contains("beta.txt") && !run.contains("folder") })

        try directory.make(["root/new-folder/inner/epsilon.txt"])
        #expect(await eventually(timeout: .seconds(2)) { run.contains("epsilon.txt") })
        await run.stop()
    }

    @Test func excludedFoldersStayOutAfterChanges() async throws {
        let run = ControllerRun(root: root, storage: storage)
        #expect(await run.ready())
        try await Task.sleep(for: .milliseconds(300))
        try directory.make(["root/node_modules/pkg/index.js", "root/visible-marker.txt"])
        #expect(await eventually(timeout: .seconds(2)) { run.contains("visible-marker.txt") })
        #expect(!run.contains("index.js"))
        await run.stop()
    }

    @Test func restartLoadsTheSnapshotAndCatchesUpWithoutAFullScan() async throws {
        let first = ControllerRun(root: root, storage: storage)
        #expect(await first.ready())
        #expect(first.controller.fullScanCount == 1)
        await first.stop()
        #expect(FileManager.default.fileExists(atPath: IndexSnapshot.url(in: storage).path))

        // Changed while Pounce was not running.
        try directory.make(["root/folder/while-away.txt"])
        try FileManager.default.removeItem(atPath: directory.sub("root/alpha.txt"))
        try await Task.sleep(for: .milliseconds(1500))

        let second = ControllerRun(root: root, storage: storage)
        #expect(await second.ready())
        #expect(
            await eventually(timeout: .seconds(3)) {
                second.contains("while-away.txt") && !second.contains("alpha.txt")
            })
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
        #expect(await second.ready())
        #expect(await eventually { second.controller.fullScanCount == 1 })
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
        #expect(await eventually { second.controller.fullScanCount == 1 })
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
        #expect(await eventually { run.contains("inside.txt") && run.contains("deep.txt") })
        try Data("x".utf8).write(to: directory.url.appending(path: "target/sub/added.txt"))
        #expect(await eventually(timeout: .seconds(3)) { run.contains("added.txt") })
        await run.stop()
    }
}
