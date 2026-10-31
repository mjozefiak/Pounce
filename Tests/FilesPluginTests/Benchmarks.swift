import Darwin
import Foundation
import PounceCore
import Synchronization
import Testing

@testable import FilesPlugin

/// Local measurements for `docs/perf.md` (spec steps 3.2 and 3.6). Off by default; run with
/// `POUNCE_BENCHMARKS=1 swift test -c release --filter FileBenchmarks`. They only read synthetic data and
/// a generated fixture tree of fake names (`POUNCE_BENCH_TREE`, default `/tmp/pounce-p3-bench/tree`),
/// never the home folder.
@Suite(
    "FileBenchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["POUNCE_BENCHMARKS"] != nil))
struct FileBenchmarks {
    static let queries = [
        "report", "pln", "x9", "budget 2024", "inv", "final summary", "dt", "photo_5", "notes 12", "swift",
        "q", "summary.md", "draft fin", "data 99", "pdf", "fold", "bgt", "rep 3", "plan_1", "zzz",
    ]

    /// The process's physical footprint (what Activity Monitor shows as Memory).
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    static func percentile(_ values: [Duration], _ fraction: Double) -> Duration {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    static func ms(_ duration: Duration) -> String {
        String(
            format: "%.1f ms",
            Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000)
    }

    static func mb(_ bytes: Int) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    @Test func searchOneMillionNames() async throws {
        let before = Self.footprint()
        let store = syntheticStore(count: 1_000_000)
        let after = Self.footprint()
        var timings: [Duration] = []
        let clock = ContinuousClock()
        for _ in 0..<5 {
            for text in Self.queries {
                timings.append(
                    try await clock.measure {
                        _ = try await FileSearch.search(TextNormalizer.query(text), in: store, limit: 50)
                    })
            }
        }
        print(
            """
            BENCH search: entries=\(store.liveCount) store=\(Self.mb(store.approximateBytes)) \
            bytes/entry=\(store.approximateBytes / store.liveCount) footprintDelta=\(Self.mb(after - before)) \
            p50=\(Self.ms(Self.percentile(timings, 0.5))) p95=\(Self.ms(Self.percentile(timings, 0.95))) \
            max=\(Self.ms(timings.max() ?? .zero)) queries=\(timings.count)
            """)
    }

    /// Builds (once) a fixture tree of fake names: `folders` folders, each with `files` files.
    static func fixtureTree(folders: Int = 2_000, files: Int = 100) throws -> String {
        let path = ProcessInfo.processInfo.environment["POUNCE_BENCH_TREE"] ?? "/tmp/pounce-p3-bench/tree"
        let marker = path + "/.complete"
        if FileManager.default.fileExists(atPath: marker) { return path }
        let words = ["report", "budget", "plan", "photo", "invoice", "notes", "draft", "final", "summary", "data"]
        for folder in 0..<folders {
            let directory = "\(path)/area \(folder % 20)/project \(folder)/\(words[folder % words.count])"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for file in 0..<files {
                let name = "\(directory)/\(words[(folder + file) % words.count])_\(file) \(folder).txt"
                let fd = open(name, O_CREAT | O_WRONLY, 0o600)
                if fd >= 0 { close(fd) }
            }
        }
        FileManager.default.createFile(atPath: marker, contents: nil)
        return path
    }

    @Test func scanFixtureTree() async throws {
        let tree = try Self.fixtureTree()
        let storage = try TemporaryDirectory()
        let before = Self.footprint()
        let clock = ContinuousClock()
        let rules = IgnoreRules.make(home: tree, userExclusions: [], includesHidden: false)
        let plan = RootPlanner.plan(
            configuredRoots: [tree], home: tree, fullDiskAccess: true, addedProtected: [], includesICloudDrive: false,
            rules: rules)
        let index = FileIndex()
        let ready = Mutex(false)
        let controller = IndexController(
            index: index, configuration: IndexController.Configuration(plan: plan, storageDirectory: storage.url),
            logger: .init(subsystem: "app.pounce.tests", category: "bench"),
            onStatus: { status in if status.phase == .ready { ready.withLock { $0 = true } } }, onChange: {})
        let start = clock.now
        let run = Task.detached { await controller.run() }
        while !ready.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let scanned = clock.now - start
        run.cancel()
        await run.value
        let store = index.snapshot
        let after = Self.footprint()
        let snapshotURL = IndexSnapshot.url(in: storage.url)
        let snapshotBytes = (try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.size] as? Int) ?? 0
        let loadStart = clock.now
        _ = try IndexSnapshot.load(from: storage.url)
        let loaded = clock.now - loadStart
        print(
            """
            BENCH scan: entries=\(store.liveCount) scan=\(Self.ms(scanned)) store=\(Self.mb(store.approximateBytes)) \
            bytes/entry=\(store.approximateBytes / max(1, store.liveCount)) footprintDelta=\(Self.mb(after - before)) \
            snapshot=\(Self.mb(snapshotBytes)) snapshotLoad=\(Self.ms(loaded))
            """)
    }
}
