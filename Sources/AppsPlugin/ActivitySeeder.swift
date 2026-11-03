import CoreServices
import Foundation

/// Reads the days an app was used, as Spotlight knows them (`kMDItemUsedDates`).
protocol UsageDatesReader: Sendable {
    func usedDates(of url: URL) -> [Date]
}

/// `kMDItemUsedDates` through `NSMetadataItem(url:)`, falling back to the public `MDItem` C API. Reads
/// one item's metadata, without a query, so nothing triggers a rescan of the app list.
struct SpotlightUsageDatesReader: UsageDatesReader {
    static let attribute = "kMDItemUsedDates"

    func usedDates(of url: URL) -> [Date] {
        if let dates = NSMetadataItem(url: url)?.value(forAttribute: Self.attribute) as? [Date] {
            return dates
        }
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return [] }
        return MDItemCopyAttribute(item, Self.attribute as CFString) as? [Date] ?? []
    }
}

/// Fills the activity store once from Spotlight's used dates, so suggestions start with history.
///
/// Runs only while `seededAt` is missing. Today's dates are skipped (the tracker counts today), the others
/// become noon of their day, only the last 90 days count, and the whole batch is merged in one step that
/// sets `seededAt`. A cancelled seed writes nothing, so it runs again on the next launch. With Spotlight
/// off, `seededAt` becomes `"skipped"`.
struct ActivitySeeder: Sendable {
    let store: ActivityStore
    let reader: any UsageDatesReader
    let now: @Sendable () -> Date
    var calendar = Calendar.current

    /// Whether the seed still has to run.
    var isNeeded: Bool {
        let snapshot = store.snapshot
        return !snapshot.isReadOnly && snapshot.seededAt == nil
    }

    func run(apps: [AppRecord], spotlightEnabled: Bool) async throws {
        guard isNeeded else { return }
        guard spotlightEnabled else {
            await store.markSeedSkipped()
            return
        }
        let today = now()
        let startOfToday = calendar.startOfDay(for: today)
        let oldest = startOfToday.addingTimeInterval(-ActivityStore.retention)
        var seed: [String: [Date]] = [:]
        for (index, app) in apps.enumerated() {
            if index % 32 == 0 {
                try Task.checkCancellation()
            }
            let days = Set(
                reader.usedDates(of: app.url).compactMap { date -> Date? in
                    guard date < startOfToday, date >= oldest else { return nil }
                    return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
                })
            if !days.isEmpty {
                seed[app.bundleIdentifier, default: []].append(contentsOf: days.sorted())
            }
        }
        try Task.checkCancellation()
        await store.merge(seed: seed, seededAt: today.formatted(.iso8601))
    }
}
