import Foundation
import Testing

@testable import AppsPlugin

@Suite struct SuggestionEngineTests {
    static let day: TimeInterval = 24 * 3600
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func app(_ id: String, _ name: String) -> AppRecord {
        AppRecord(bundleIdentifier: id, path: "/Applications/\(name).app", name: name)
    }

    func entry(frecency: Double, daysAgo: Double, uses: Int = 1) -> ActivityEntry {
        ActivityEntry(
            frecency: frecency, lastUsedAt: now.timeIntervalSince1970 - daysAgo * Self.day, useCount: uses)
    }

    var apps: [AppRecord] {
        [
            app("com.example.mail", "Mail"), app("com.example.notes", "Notes"),
            app("com.example.chat", "Chat"), app("com.lintelapp.Lintel", "Lintel"),
            app("com.example.maps", "Maps"), app("com.example.books", "Books"),
            app("com.example.music", "Music"), app("com.example.photos", "Photos"),
        ]
    }

    @Test func ordersByDecayedFrecencyAndLimits() {
        let snapshot = ActivitySnapshot(apps: [
            "com.example.mail": entry(frecency: 4, daysAgo: 0),
            // Higher stored frecency, but 14 days of decay (two half-lives) leave 2.5.
            "com.example.notes": entry(frecency: 10, daysAgo: 14),
            "com.example.chat": entry(frecency: 3, daysAgo: 0),
            "com.example.maps": entry(frecency: 2, daysAgo: 0),
            "com.example.books": entry(frecency: 1.5, daysAgo: 0),
            "com.example.music": entry(frecency: 1, daysAgo: 0),
        ])
        let result = SuggestionEngine.suggestions(
            snapshot: snapshot, apps: apps, hidden: [], running: [], ownBundleIdentifier: nil, now: now)
        #expect(
            result.map(\.record.name) == ["Mail", "Chat", "Notes", "Maps", "Books"])
        #expect(abs(result[2].score - 2.5) < 1e-9)
    }

    @Test func skipsLintelHiddenAndUnknownApps() {
        let snapshot = ActivitySnapshot(apps: [
            "com.lintelapp.Lintel": entry(frecency: 9, daysAgo: 0),
            "com.example.mail": entry(frecency: 8, daysAgo: 0),
            "com.example.uninstalled": entry(frecency: 7, daysAgo: 0),
            "com.example.notes": entry(frecency: 1, daysAgo: 0),
        ])
        let result = SuggestionEngine.suggestions(
            snapshot: snapshot, apps: apps, hidden: ["com.example.mail"], running: [],
            ownBundleIdentifier: "com.lintelapp.Lintel", now: now)
        #expect(result.map(\.record.bundleIdentifier) == ["com.example.notes"])
    }

    @Test func tiesGoToTheLatestUseThenTheName() {
        // Same decayed score: 2 now, and 4 one half-life (7 days) ago.
        let snapshot = ActivitySnapshot(apps: [
            "com.example.notes": entry(frecency: 4, daysAgo: 7),
            "com.example.mail": entry(frecency: 2, daysAgo: 0),
            "com.example.photos": entry(frecency: 1, daysAgo: 1),
            "com.example.books": entry(frecency: 1, daysAgo: 1),
        ])
        let result = SuggestionEngine.suggestions(
            snapshot: snapshot, apps: apps, hidden: [], running: [], ownBundleIdentifier: nil, now: now,
            halfLife: 7 * Self.day)
        #expect(result.map(\.record.name) == ["Mail", "Notes", "Books", "Photos"])
    }

    @Test func flagsRunningApps() {
        let snapshot = ActivitySnapshot(apps: [
            "com.example.mail": entry(frecency: 2, daysAgo: 0),
            "com.example.notes": entry(frecency: 1, daysAgo: 0),
        ])
        let result = SuggestionEngine.suggestions(
            snapshot: snapshot, apps: apps, hidden: [], running: ["com.example.notes"], ownBundleIdentifier: nil,
            now: now)
        #expect(result.map(\.isRunning) == [false, true])
    }

    @Test func aReadOnlyOrEmptySnapshotSuggestsNothing() {
        var snapshot = ActivitySnapshot(apps: ["com.example.mail": entry(frecency: 2, daysAgo: 0)])
        snapshot.isReadOnly = true
        #expect(
            SuggestionEngine.suggestions(
                snapshot: snapshot, apps: apps, hidden: [], running: [], ownBundleIdentifier: nil, now: now
            ).isEmpty)
        #expect(
            SuggestionEngine.suggestions(
                snapshot: .empty, apps: apps, hidden: [], running: [], ownBundleIdentifier: nil, now: now
            ).isEmpty)
    }
}
