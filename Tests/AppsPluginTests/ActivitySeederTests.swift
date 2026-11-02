import Foundation
import Testing

@testable import AppsPlugin

@Suite struct ActivitySeederTests {
    static let day: TimeInterval = 24 * 3600

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    let apps = [
        AppRecord(bundleIdentifier: "com.example.mail", path: "/Applications/Mail.app", name: "Mail"),
        AppRecord(bundleIdentifier: "com.example.calendar", path: "/Applications/Calendar.app", name: "Calendar"),
        AppRecord(bundleIdentifier: "com.example.safari", path: "/Applications/Safari.app", name: "Safari"),
    ]

    func makeSeeder(_ reader: any UsageDatesReader, _ directory: TemporaryDirectory, time: VirtualTime) async
        -> ActivitySeeder
    {
        let store = ActivityStore(directory: directory.url, now: time.now, clock: NeverClock())
        await store.load()
        return ActivitySeeder(store: store, reader: reader, now: time.now, calendar: calendar)
    }

    @Test func seedsPastDaysAtNoonAndSkipsToday() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()  // 2027-01-15 08:00 UTC
        let now = time.date
        let yesterday = now.addingTimeInterval(-Self.day)
        let reader = FakeUsageDatesReader(dates: [
            "/Applications/Mail.app": [now, yesterday, now.addingTimeInterval(-91 * Self.day)],
            "/Applications/Calendar.app": [now.addingTimeInterval(-3 * Self.day)],
            "/Applications/Other.app": [yesterday],
        ])
        let seeder = await makeSeeder(reader, directory, time: time)
        try await seeder.run(apps: apps, spotlightEnabled: true)

        let snapshot = seeder.store.snapshot
        let noonYesterday = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: yesterday))
        #expect(snapshot.apps["com.example.mail"]?.useCount == 1)
        #expect(snapshot.apps["com.example.mail"]?.lastUsedAt == noonYesterday.timeIntervalSince1970)
        #expect(snapshot.apps["com.example.calendar"]?.useCount == 1)
        // Safari has no used dates (null), and apps outside the index are never read.
        #expect(snapshot.apps["com.example.safari"] == nil)
        #expect(snapshot.apps.count == 2)
        #expect(snapshot.seededAt == now.formatted(.iso8601))
        #expect(!seeder.isNeeded)
    }

    @Test func spotlightOffSkipsTheSeed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let reader = FakeUsageDatesReader(dates: ["/Applications/Mail.app": [time.date.addingTimeInterval(-Self.day)]])
        let seeder = await makeSeeder(reader, directory, time: time)
        try await seeder.run(apps: apps, spotlightEnabled: false)
        #expect(seeder.store.snapshot.seededAt == ActivityStore.seedSkipped)
        #expect(seeder.store.snapshot.apps.isEmpty)
    }

    @Test func anExistingSeedDateMeansNoSeed() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let reader = FakeUsageDatesReader(dates: ["/Applications/Mail.app": [time.date.addingTimeInterval(-Self.day)]])
        let seeder = await makeSeeder(reader, directory, time: time)
        await seeder.store.markSeedSkipped()
        try await seeder.run(apps: apps, spotlightEnabled: true)
        #expect(seeder.store.snapshot.apps.isEmpty)
        #expect(seeder.store.snapshot.seededAt == ActivityStore.seedSkipped)
    }

    /// Cancels the reading task after the first app.
    struct CancellingReader: UsageDatesReader {
        let dates: [Date]

        func usedDates(of url: URL) -> [Date] {
            withUnsafeCurrentTask { $0?.cancel() }
            return dates
        }
    }

    @Test func aCancelledSeedWritesNothing() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let seeder = await makeSeeder(
            CancellingReader(dates: [time.date.addingTimeInterval(-Self.day)]), directory, time: time)
        await #expect(throws: CancellationError.self) {
            try await seeder.run(apps: apps, spotlightEnabled: true)
        }
        #expect(seeder.store.snapshot.apps.isEmpty)
        #expect(seeder.store.snapshot.seededAt == nil)
        #expect(seeder.isNeeded)
    }

    @Test func theSpotlightReaderAnswersForAMissingBundle() {
        let reader = SpotlightUsageDatesReader()
        #expect(reader.usedDates(of: URL(filePath: "/nonexistent-\(UUID().uuidString).app")).isEmpty)
    }
}
