import Foundation
import LintelCore
import LintelKit
import Testing

@testable import AppsPlugin

/// Local measurement for `docs/perf.md` (spec budget "Zapytanie o aplikacje < 5 ms", step 4.5). Off by
/// default; run with `LINTEL_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter
/// AppBenchmarks`. Synthetic app names only.
@Suite(
    "AppBenchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["LINTEL_BENCHMARKS"] != nil))
@MainActor
struct AppBenchmarks {
    static let queries = [
        "vsc", "term", "calc", "safari", "x", "notes", "pho", "mail", "stu", "zz", "music", "pr", "cod", "kal",
        "system settings", "act mon", "fin", "a", "preview", "keyn",
    ]

    /// `count` apps with realistic names: a few hundred words combined, each with an alias.
    static func records(count: Int) -> [AppRecord] {
        let first = [
            "Visual", "Studio", "Code", "Terminal", "Calculator", "Safari", "Notes", "Photos", "Mail", "Music",
            "Preview", "Keynote", "Pages", "Numbers", "Finder", "Activity", "Monitor", "System", "Settings",
            "Xcode", "Docker", "Slack", "Zoom", "Figma", "Chrome", "Firefox", "Spotify", "Discord", "Notion",
            "Things", "Bear", "Craft", "Linear", "Raycast", "Tower", "Transmit", "Affinity", "Pixelmator",
        ]
        let second = ["", " Pro", " Helper", " Studio", " Lite", " Beta", " Plus", " Editor", " Manager", " Player"]
        return (0..<count).map { index in
            let name =
                first[index % first.count] + second[(index / first.count) % second.count]
                + (index >= first.count * second.count ? " \(index)" : "")
            return AppRecord(
                bundleIdentifier: "com.example.app\(index)", path: "/Applications/\(name).app", name: name,
                aliases: [name.replacingOccurrences(of: " ", with: "")])
        }
    }

    static func ms(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }

    @Test(arguments: [300, 1_000])
    func searchApps(count: Int) async throws {
        let store = AppStore()
        store.publish(Self.records(count: count))
        let source = AppSearchSource(store: store, usage: RecordingUsage(), workspace: RecordingWorkspace())
        let clock = ContinuousClock()
        var timings: [Duration] = []
        for _ in 0..<10 {
            for text in Self.queries {
                let query = TextNormalizer.query(text)
                timings.append(try await clock.measure { _ = try await source.search(query, limit: 50) })
            }
        }
        let sorted = timings.sorted()
        let p50 = Self.ms(sorted[sorted.count / 2])
        let p95 = Self.ms(sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))])
        print(
            String(
                format: "BENCH apps: apps=%d p50=%.2f ms p95=%.2f ms max=%.2f ms queries=%d", count, p50, p95,
                Self.ms(sorted[sorted.count - 1]), timings.count))
    }

    /// The suggestion query (app suggestions spec): `count` apps in the index, every one with activity.
    @Test(arguments: [300, 1_000])
    func suggestApps(count: Int) async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let activity = ActivityStore(directory: directory.url, clock: NeverClock())
        await activity.load()
        let records = Self.records(count: count)
        let now = Date()
        for (index, record) in records.enumerated() {
            for use in 0..<(index % 7 + 1) {
                await activity.recordUse(of: record.bundleIdentifier, at: now.addingTimeInterval(-Double(use) * 3_600))
            }
        }
        let store = AppStore()
        store.publish(records)
        let source = AppSuggestionSource(
            store: store, activity: activity, settings: PluginSettings(pluginID: "apps", store: MemorySettings()),
            usage: RecordingUsage(), workspace: RecordingWorkspace(), ownBundleIdentifier: nil,
            resultsChanged: {})
        let clock = ContinuousClock()
        var timings: [Duration] = []
        for _ in 0..<200 {
            timings.append(try await clock.measure { _ = try await source.suggestions(limit: 5) })
        }
        let sorted = timings.sorted()
        print(
            String(
                format: "BENCH suggestions: apps=%d p50=%.2f ms p95=%.2f ms max=%.2f ms", count,
                Self.ms(sorted[sorted.count / 2]), Self.ms(sorted[Int(Double(sorted.count) * 0.95)]),
                Self.ms(sorted[sorted.count - 1])))
        await activity.close()
    }

    /// The one-time seed from Spotlight over the real `/Applications` of this Mac (reads only; the store
    /// lives in a temporary directory).
    @Test func seedFromSpotlight() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let root = URL(filePath: "/Applications")
        let apps = (try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "app" }
            .compactMap { url -> AppRecord? in
                guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
                return AppRecord(
                    bundleIdentifier: id, path: url.path(percentEncoded: false),
                    name: url.deletingPathExtension().lastPathComponent)
            }
        let activity = ActivityStore(directory: directory.url, clock: NeverClock())
        await activity.load()
        let seeder = ActivitySeeder(store: activity, reader: SpotlightUsageDatesReader(), now: { Date() })
        let elapsed = try await ContinuousClock().measure {
            try await seeder.run(apps: apps, spotlightEnabled: true)
        }
        print(
            String(
                format: "BENCH seed: apps=%d seeded=%d time=%.1f ms", apps.count, activity.snapshot.apps.count,
                Self.ms(elapsed)))
        await activity.close()
    }
}
