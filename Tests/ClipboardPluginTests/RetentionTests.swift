import Foundation
import PounceKit
import Testing
import os

@testable import ClipboardPlugin

@Suite @MainActor final class RetentionJobTests {
    let temporary: TemporaryDirectory
    let store: ClipStore
    let day: TimeInterval = 86_400
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        temporary = try TemporaryDirectory()
        store = try ClipStore.open(in: temporary.url, keys: try testKeys())
    }

    deinit {
        try? store.close()
    }

    func job(now: Date) -> RetentionJob {
        RetentionJob(
            clock: ContinuousClock(), now: { now }, logger: Logger(subsystem: "app.pounce.tests", category: "clipboard")
        )
    }

    var blobCount: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.blobsDirectory.path)) ?? []).count
    }

    @Test func deletesEntriesOlderThanTheRetentionWithTheirBlobs() async throws {
        let big = Data(repeating: 1, count: ClipStore.inlineLimit + 1)
        try store.insert(
            draft(
                "fake old image", kind: .image, at: now.addingTimeInterval(-31 * day),
                items: [PasteboardItem(representations: [.init(type: "public.tiff", data: big)])]))
        try store.insert(draft("fake recent", at: now.addingTimeInterval(-29 * day)))
        #expect(blobCount == 1)

        #expect(await job(now: now).run(store: store, policy: .default))
        #expect(try store.recent(limit: 10).map(\.previewText) == ["fake recent"])
        #expect(blobCount == 0)
    }

    @Test func keepsOnlyTheMostRecentlyUsedEntries() async throws {
        for index in 0..<5 {
            try store.insert(draft("fake \(index)", at: now.addingTimeInterval(Double(index - 10))))
        }
        #expect(await job(now: now).run(store: store, policy: RetentionPolicy(days: 30, maximumCount: 3)))
        #expect(try store.recent(limit: 10).map(\.previewText) == ["fake 4", "fake 3", "fake 2"])
        #expect(!(await job(now: now).run(store: store, policy: RetentionPolicy(days: 30, maximumCount: 3))))
    }

    @Test func aRecentUseKeepsAnOldEntry() async throws {
        guard case .inserted(let id) = try store.insert(draft("fake reused", at: now.addingTimeInterval(-60 * day)))
        else {
            Issue.record("expected an insert")
            return
        }
        try store.markUsed(id, at: now.addingTimeInterval(-day))
        #expect(!(await job(now: now).run(store: store, policy: .default)))
        #expect(try store.count() == 1)
    }

    @Test func sweepsOrphansAtMostOnceADay() async throws {
        let job = job(now: now)
        FileManager.default.createFile(atPath: store.blobURL(UUID().uuidString).path, contents: Data())
        await job.run(store: store, policy: .default)
        #expect(blobCount == 0)
        FileManager.default.createFile(atPath: store.blobURL(UUID().uuidString).path, contents: Data())
        await job.run(store: store, policy: .default)
        #expect(blobCount == 1)
    }

    @Test func startRunsOnceRightAway() async throws {
        try store.insert(draft("fake ancient", at: now.addingTimeInterval(-90 * day)))
        let job = job(now: now)
        var changes = 0
        var hourlyRuns = 0
        let store = store
        job.start(store: { store }, policy: { .default }, hourly: { hourlyRuns += 1 }, changed: { changes += 1 })
        defer { job.stop() }
        for _ in 0..<50 where changes == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(changes == 1)
        #expect(hourlyRuns == 1)
        #expect(job.isRunning)
        job.stop()
        #expect(!job.isRunning)
    }

    @Test func theCutoffUsesWholeDays() {
        #expect(RetentionPolicy(days: 7, maximumCount: 1).cutoff(now: now) == now.addingTimeInterval(-7 * day))
        #expect(RetentionPolicy(days: 0, maximumCount: 1).cutoff(now: now) == now.addingTimeInterval(-day))
    }
}
