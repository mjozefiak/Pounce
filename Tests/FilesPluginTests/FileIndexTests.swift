import Foundation
import PounceCore
import PounceKit
import Testing

@testable import FilesPlugin

/// Builds an index from relative paths (a trailing `/` makes a folder) below one root.
func makeStore(root: String = "/r", _ paths: [String], modified: UInt32 = 1_700_000_000) -> NameStore {
    var store = NameStore()
    let rootNode = store.addRoot(path: root, kind: .directory, modified: modified)
    var folders: [String: Int32] = ["": rootNode]
    for path in paths.sorted() {
        let isFolder = path.hasSuffix("/")
        let trimmed = isFolder ? String(path.dropLast()) : path
        let parentPath =
            trimmed.contains("/") ? String(trimmed[..<(trimmed.lastIndex(of: "/") ?? trimmed.startIndex)]) : ""
        let name = PathText.name(trimmed)
        guard let parent = folders[parentPath] else { continue }
        let kind: EntryKind = isFolder ? .directory : (name.hasSuffix(".app") ? .package : .file)
        let node = store.addChild(name, kind: kind, modified: modified, parent: parent)
        if isFolder { folders[trimmed] = node }
    }
    return store
}

func query(_ text: String) -> NormalizedQuery { TextNormalizer.query(text) }

@Suite struct NameStoreTests {
    @Test func pathsDepthAndLookup() throws {
        let store = makeStore(["Docs/", "Docs/Plan.md", "Docs/Old/", "Docs/Old/Plan v1.md", "Żółw.txt"])
        #expect(store.liveCount == 5)
        let plan = try #require(store.locate("/r/Docs/Old/Plan v1.md").node)
        #expect(store.path(plan) == "/r/Docs/Old/Plan v1.md")
        #expect(store.depth(plan) == 2)
        #expect(store.locate("/r/Docs/Missing/x").node == nil)
        #expect(store.locate("/r/Docs/Missing/x").deepest.map(store.path) == "/r/Docs")
        #expect(store.locate("/elsewhere").deepest == nil)
        let turtle = try #require(store.locate("/r/Żółw.txt").node)
        #expect(store.name(turtle) == "Żółw.txt")
        #expect(store.withFoldedBytes(Int(turtle)) { String(decoding: Array($0), as: UTF8.self) } == "zolw.txt")
    }

    @Test func removeAndCompactKeepTheLiveTree() throws {
        var store = makeStore(["A/", "A/one.txt", "A/two.txt", "B/", "B/three.txt"])
        let folder = try #require(store.locate("/r/A").node)
        store.remove(folder)
        #expect(store.liveCount == 2)
        #expect(store.locate("/r/A/one.txt").node == nil)
        let compact = store.compacted()
        #expect(compact.nodeCount == 3)
        #expect(compact.liveCount == 2)
        #expect(compact.locate("/r/B/three.txt").node.map(compact.path) == "/r/B/three.txt")
        #expect(compact.removedCount == 0)
    }
}

@Suite struct FileSearchTests {
    /// Spec step 3.2: top-N correctness — best tier first, limit honoured.
    @Test func bestTierFirstAndLimit() async throws {
        let store = makeStore([
            "report.pdf", "Report Final.docx", "old-report.txt", "preport.txt", "r_e_p_o_r_t.md", "notes.txt",
            "Projects/", "Projects/Q3 Report.key",
        ])
        let hits = try await FileSearch.search(query("report"), in: store, limit: 4)
        #expect(hits.count == 4)
        #expect(hits[0].name == "report.pdf")
        #expect(hits[0].match.tier == .prefix)
        #expect(hits.map(\.match.tier) == hits.map(\.match.tier).sorted())
        #expect(!hits.contains { $0.name == "notes.txt" })
        #expect(hits[0].path == "/r/report.pdf")
        #expect(hits[0].match.highlightRanges == [0..<6])
    }

    @Test func diacriticsAndAcronyms() async throws {
        let store = makeStore(["Łódź zdjęcia.jpg", "Visual Studio Code.app", "vsc.txt"])
        let polish = try await FileSearch.search(query("lodz"), in: store, limit: 5)
        #expect(polish.first?.name == "Łódź zdjęcia.jpg")
        let acronym = try await FileSearch.search(query("vsc"), in: store, limit: 5)
        #expect(acronym.map(\.name) == ["vsc.txt", "Visual Studio Code.app"])
        #expect(acronym[1].match.tier == .wordStart)
    }

    @Test func deeperAndOlderItemsLoseWithinATier() async throws {
        var store = NameStore()
        let root = store.addRoot(path: "/r", kind: .directory, modified: 0)
        var parent = root
        for level in 0..<6 {
            parent = store.addChild("level\(level)", kind: .directory, modified: 0, parent: parent)
        }
        store.addChild("budget.xlsx", kind: .file, modified: 0, parent: parent)
        store.addChild("budget.numbers", kind: .file, modified: 0, parent: root)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let hits = try await FileSearch.search(query("budget"), in: store, limit: 2, now: now)
        #expect(hits.map(\.name) == ["budget.numbers", "budget.xlsx"])
        #expect(hits[0].boost > hits[1].boost)

        var fresh = makeStore(["a/", "a/plan.txt"], modified: 0)
        let recent = UInt32(now.timeIntervalSince1970) - 60
        fresh.addChild("plan.md", kind: .file, modified: recent, parent: try #require(fresh.root("/r")))
        let byAge = try await FileSearch.search(query("plan"), in: fresh, limit: 2, now: now)
        #expect(byAge.first?.name == "plan.md")
    }

    @Test func removedNodesAndRootsAreNeverResults() async throws {
        var store = makeStore(["gone.txt", "kept.txt"])
        store.remove(try #require(store.locate("/r/gone.txt").node))
        #expect(try await FileSearch.search(query("gone"), in: store, limit: 5).isEmpty)
        #expect(try await FileSearch.search(query("r"), in: store, limit: 5).allSatisfy { $0.name != "/r" })
        #expect(try await FileSearch.search(query(""), in: store, limit: 5).isEmpty)
    }

    /// Spec step 3.2: cancellation stops a search.
    @Test func cancellationStopsTheSearch() async throws {
        let store = syntheticStore(count: 200_000)
        let task = Task { try await FileSearch.search(query("e"), in: store, limit: 50, chunks: 1) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Spec step 3.2: CI smoke test with a loose limit (the 1 M / p95 < 30 ms benchmark is local, see
    /// `docs/perf.md`).
    @Test func smokeBenchmark() async throws {
        let store = syntheticStore(count: 200_000)
        let clock = ContinuousClock()
        var worst = Duration.zero
        for text in ["report", "pln", "x9", "budget 2024"] {
            let elapsed = try await clock.measure {
                _ = try await FileSearch.search(query(text), in: store, limit: 50)
            }
            worst = max(worst, elapsed)
        }
        #expect(worst < .seconds(2))
    }

    @Test func byteMatcherAgreesWithTheMatcherOnTiers() throws {
        let names = [
            "plan.txt", "my plan.txt", "airplane.txt", "p-l-a-n.md", "Plan", "xplanx", "project_log_a_n",
            "MyPlan.txt", "myplan.txt", "draft+plan.md", "Q3Plan.key", "Project Log And Notes",
        ]
        for name in names {
            let store = makeStore([name])
            let node = try #require(store.locate("/r/\(name)").node)
            let approximate = Array("plan".utf8).withUnsafeBufferPointer { q in
                store.withSearchBytes(Int(node)) { ByteMatcher.match(q, in: $0, original: $1) }
            }
            let exact = FuzzyMatcher.match(Array("plan".unicodeScalars), in: NormalizedText(name))
            #expect(approximate?.0 == exact?.tier, "\(name)")
        }
    }

    /// Camel-case and letter-to-digit boundaries are word starts for `FuzzyMatcher`, so the byte pass must
    /// not let substring matches crowd such a name out of the top `2 × limit`.
    @Test func camelCaseWordStartsAreNotCrowdedOut() async throws {
        var names = (0..<100).map { "xdelegatex\($0).txt" }
        names += ["AppDelegate.swift", "report2024.pdf"]
        names += (0..<100).map { "a12024b\($0).txt" }
        let store = makeStore(names)
        let camel = try await FileSearch.search(query("delegate"), in: store, limit: 5)
        #expect(camel.first?.name == "AppDelegate.swift")
        #expect(camel.first?.match.tier == .wordStart)
        let acronym = try await FileSearch.search(query("ad"), in: store, limit: 5)
        #expect(acronym.contains { $0.name == "AppDelegate.swift" })
        let digits = try await FileSearch.search(query("2024"), in: store, limit: 5)
        #expect(digits.first?.name == "report2024.pdf")
    }
}

/// A synthetic index of `count` names in nested folders.
func syntheticStore(count: Int) -> NameStore {
    let words = ["report", "budget", "plan", "photo", "invoice", "notes", "draft", "final", "summary", "data"]
    let extensions = ["txt", "pdf", "md", "swift", "png", "xlsx"]
    var store = NameStore()
    let root = store.addRoot(path: "/synthetic", kind: .directory, modified: 1_700_000_000)
    var folders = [root]
    var generator = SplitMix(seed: 42)
    for index in 0..<count {
        let parent = folders[Int(generator.next() % UInt64(folders.count))]
        let word = words[Int(generator.next() % UInt64(words.count))]
        if index % 20 == 0 {
            folders.append(
                store.addChild("\(word) folder \(index)", kind: .directory, modified: 1_700_000_000, parent: parent))
        } else {
            let ext = extensions[Int(generator.next() % UInt64(extensions.count))]
            store.addChild(
                "\(word)_\(index % 997) \(index).\(ext)", kind: .file,
                modified: 1_700_000_000 + UInt32(index % 86_400), parent: parent)
        }
    }
    return store
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct FileIndexTests {
    @Test func scanBatchesBuildTheTree() async throws {
        let index = FileIndex()
        let roots = await index.setRoots(["/r"]) { _ in (.directory, 0) }
        let root = try #require(roots["/r"])
        let scan = await index.beginScan(at: root)
        await index.absorb(
            [
                ScannedDirectory(
                    id: 0,
                    entries: [
                        ScannedEntry(name: "Docs", kind: .directory, modified: 1, directoryID: 1),
                        ScannedEntry(name: "a.txt", kind: .file, modified: 1, directoryID: nil),
                    ])
            ], scan: scan)
        await index.absorb(
            [
                ScannedDirectory(
                    id: 1, entries: [ScannedEntry(name: "b.txt", kind: .file, modified: 1, directoryID: nil)])
            ],
            scan: scan)
        await index.endScan(scan)
        #expect(index.snapshot.liveCount == 0)
        await index.publish()
        let snapshot = index.snapshot
        #expect(snapshot.liveCount == 3)
        #expect(snapshot.locate("/r/Docs/b.txt").node != nil)
    }

    @Test func reconcileAddsRemovesAndReportsNewFolders() async throws {
        let index = FileIndex(makeStore(["keep.txt", "gone.txt", "swap"]))
        let snapshot = index.snapshot
        let root = try #require(snapshot.root("/r"))
        let newFolders = await index.reconcile(
            node: root, path: "/r",
            listing: [
                ScannedEntry(name: "keep.txt", kind: .file, modified: 99, directoryID: nil),
                ScannedEntry(name: "swap", kind: .directory, modified: 1, directoryID: nil),
                ScannedEntry(name: "New", kind: .directory, modified: 1, directoryID: nil),
            ])
        await index.publish()
        let after = index.snapshot
        #expect(Set(after.children(root).map(after.name)) == ["keep.txt", "swap", "New"])
        #expect(Set(newFolders.map(\.path)) == ["/r/swap", "/r/New"])
        #expect(after.locate("/r/keep.txt").node.map { after.modified[Int($0)] } == 99)
        // A stale node/path pair does nothing.
        #expect(await index.reconcile(node: root, path: "/elsewhere", listing: []).isEmpty)
    }

    /// Spec step 3.2: concurrent test — FSEvents-style changes applied while searches run (also run under
    /// `--sanitize=thread` in CI). Every search sees a whole batch or none of it.
    @Test func searchesDuringConcurrentChangesSeeWholeBatches() async throws {
        let index = FileIndex(makeStore(["Inbox/"]))
        let inbox = try #require(index.snapshot.locate("/r/Inbox").node)
        let writer = Task {
            for round in 0..<200 {
                let listing = (0..<10).map {
                    ScannedEntry(name: "batch\(round) item\($0).txt", kind: .file, modified: 1, directoryID: nil)
                }
                _ = await index.reconcile(node: inbox, path: "/r/Inbox", listing: listing)
                await index.publish()
            }
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<100 {
                        let snapshot = index.snapshot
                        let hits = try await FileSearch.search(query("batch"), in: snapshot, limit: 50)
                        // A batch replaces all ten items at once, so a search finds 0 or exactly 10.
                        #expect(hits.count == 0 || hits.count == 10)
                        #expect(Set(hits.map { $0.name.split(separator: " ")[0] }).count <= 1)
                    }
                }
            }
            try await group.waitForAll()
        }
        await writer.value
        #expect(index.snapshot.children(inbox).count == 10)
    }
}
