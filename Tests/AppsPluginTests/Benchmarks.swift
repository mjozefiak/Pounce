import Foundation
import PounceCore
import PounceKit
import Testing

@testable import AppsPlugin

/// Local measurement for `docs/perf.md` (spec budget "Zapytanie o aplikacje < 5 ms", step 4.5). Off by
/// default; run with `POUNCE_BENCHMARKS=1 swift test -c release -Xswiftc -enable-testing --filter
/// AppBenchmarks`. Synthetic app names only.
@Suite(
    "AppBenchmarks", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["POUNCE_BENCHMARKS"] != nil))
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
}
