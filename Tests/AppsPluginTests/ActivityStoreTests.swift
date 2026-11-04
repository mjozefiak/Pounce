import Foundation
import LintelCore
import LintelKit
import LintelPersistence
import Testing

@testable import AppsPlugin

@Suite struct ActivityStoreTests {
    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 24 * 3600

    func makeStore(_ directory: TemporaryDirectory, time: VirtualTime, clock: any Clock<Duration> = NeverClock())
        -> ActivityStore
    {
        ActivityStore(directory: directory.url, now: time.now, clock: clock)
    }

    @Test func aUseAtNowMatchesTheRankingDatabase() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let store = makeStore(directory, time: time)
        await store.load()
        let repository = try UsageRepository.inMemory(halfLife: Ranker.frecencyHalfLife)
        let key = ItemKey(pluginID: "apps", key: "com.example.notes")
        for offset in [0, 2 * Self.hour, 3 * Self.day] {
            time.advance(to: offset)
            await store.recordUse(of: "com.example.notes", at: time.date)
            try await repository.recordUse(of: key, queryPrefix: nil, at: time.date)
        }
        let stats = try #require(try await repository.stats(for: [key], queryPrefix: nil)[key])
        let entry = try #require(store.snapshot.apps["com.example.notes"])
        #expect(abs(entry.frecency - stats.frecency) < 1e-9)
        #expect(entry.useCount == 3)
        #expect(entry.lastUsedAt == time.date.timeIntervalSince1970)
    }

    @Test func mergingDoesNotDependOnOrder() {
        let dates: [Double] = [1000, 50_000, 400_000, 7000]
        var forward = ActivityEntry.firstUse(at: dates[0])
        for date in dates.dropFirst() {
            forward.addUse(at: date, halfLife: Ranker.frecencyHalfLife)
        }
        var backward = ActivityEntry.firstUse(at: dates[3])
        for date in dates.dropLast().reversed() {
            backward.addUse(at: date, halfLife: Ranker.frecencyHalfLife)
        }
        #expect(abs(forward.frecency - backward.frecency) < 1e-9)
        #expect(forward.lastUsedAt == 400_000)
        #expect(backward.lastUsedAt == 400_000)
        #expect(forward.useCount == 4)
    }

    @Test func theSeedMergesWithLiveUsesAndKeepsTheNewestDate() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        time.advance(to: 10 * Self.day)
        let store = makeStore(directory, time: time)
        await store.load()
        await store.recordUse(of: "com.example.mail", at: time.date)
        let older = time.date.addingTimeInterval(-3 * Self.day)
        await store.merge(seed: ["com.example.mail": [older], "com.example.calendar": [older]], seededAt: "seeded")
        let snapshot = store.snapshot
        #expect(snapshot.apps["com.example.mail"]?.useCount == 2)
        #expect(snapshot.apps["com.example.mail"]?.lastUsedAt == time.date.timeIntervalSince1970)
        #expect(snapshot.apps["com.example.calendar"]?.lastUsedAt == older.timeIntervalSince1970)
        #expect(snapshot.seededAt == "seeded")
        // A second seed is ignored.
        await store.merge(seed: ["com.example.other": [older]], seededAt: "again")
        #expect(store.snapshot.apps["com.example.other"] == nil)
        #expect(store.snapshot.seededAt == "seeded")
    }

    @Test func oldEntriesArePrunedOnLoadAndOnWrite() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let start = time.date.timeIntervalSince1970
        let file = ActivityStore.FileContents(
            version: 1,
            seededAt: nil,
            apps: [
                "com.example.old": ActivityEntry(frecency: 1, lastUsedAt: start - 91 * Self.day, useCount: 1),
                "com.example.new": ActivityEntry(frecency: 1, lastUsedAt: start - Self.day, useCount: 1),
            ]
        )
        try JSONEncoder().encode(file).write(to: directory.url.appending(path: ActivityStore.fileName))
        let store = makeStore(directory, time: time)
        await store.load()
        #expect(Set(store.snapshot.apps.keys) == ["com.example.new"])

        // 90 days later the remaining entry expires on the next write.
        time.advance(to: 90 * Self.day)
        await store.recordUse(of: "com.example.fresh", at: time.date)
        await store.close()
        let saved = try JSONDecoder().decode(
            ActivityStore.FileContents.self,
            from: Data(contentsOf: directory.url.appending(path: ActivityStore.fileName)))
        #expect(Set(saved.apps.keys) == ["com.example.fresh"])
    }

    @Test func aCorruptFileIsKeptAsOneCopy() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let file = directory.url.appending(path: ActivityStore.fileName)
        let corrupt = directory.url.appending(path: ActivityStore.corruptFileName)

        try Data("not json".utf8).write(to: file)
        let first = makeStore(directory, time: time)
        await first.load()
        #expect(first.snapshot == .empty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: corrupt) == Data("not json".utf8))

        // Version 1 without the required fields is corrupt too; its copy replaces the previous one.
        try Data(#"{"version":1}"#.utf8).write(to: file)
        let second = makeStore(directory, time: time)
        await second.load()
        #expect(second.snapshot == .empty)
        #expect(try Data(contentsOf: corrupt) == Data(#"{"version":1}"#.utf8))
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
            .filter { $0.hasPrefix(ActivityStore.fileName) }
        #expect(copies == [ActivityStore.corruptFileName])
    }

    @Test func aNewerFileIsReadOnlyAndUntouched() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let file = directory.url.appending(path: ActivityStore.fileName)
        let original = Data(#"{"version":2,"apps":{"com.example.notes":{"score":3}},"future":true}"#.utf8)
        try original.write(to: file)
        let store = makeStore(directory, time: time)
        await store.load()
        #expect(await store.isReadOnly)
        #expect(store.snapshot.isReadOnly)
        #expect(store.snapshot.apps.isEmpty)

        await store.recordUse(of: "com.example.notes", at: time.date)
        await store.merge(seed: ["com.example.notes": [time.date]], seededAt: "seeded")
        await store.markSeedSkipped()
        await store.removeAll()
        await store.close()
        #expect(store.snapshot.apps.isEmpty)
        #expect(store.snapshot.seededAt == nil)
        #expect(try Data(contentsOf: file) == original)
        #expect(
            !FileManager.default.fileExists(atPath: directory.url.appending(path: ActivityStore.corruptFileName).path))
    }

    @Test func anUnreadableFileIsNeverReplaced() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let file = directory.url.appending(path: ActivityStore.fileName)
        let original = Data(#"{"version":1,"apps":{}}"#.utf8)
        try original.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let store = makeStore(directory, time: time)
        await store.load()
        // Suggestions still work from memory for this session…
        await store.recordUse(of: "com.example.notes", at: time.date)
        #expect(store.snapshot.apps["com.example.notes"]?.useCount == 1)
        await store.close()
        // …but the file is left as it was.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try Data(contentsOf: file) == original)
        #expect(
            !FileManager.default.fileExists(atPath: directory.url.appending(path: ActivityStore.corruptFileName).path))
    }

    @Test func clearingKeepsTheSeedFromComingBack() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let store = makeStore(directory, time: time)
        await store.load()
        await store.recordUse(of: "com.example.notes", at: time.date)
        await store.removeAll()
        #expect(store.snapshot.apps.isEmpty)
        #expect(store.snapshot.seededAt == ActivityStore.seedCleared)
        await store.merge(seed: ["com.example.notes": [time.date]], seededAt: "seeded")
        #expect(store.snapshot.apps.isEmpty)

        // After a finished seed, clearing keeps its date.
        let seeded = makeStore(try TemporaryDirectory(), time: time)
        await seeded.load()
        await seeded.merge(seed: ["com.example.notes": [time.date]], seededAt: "2026-11-02T09:14:00Z")
        await seeded.removeAll()
        #expect(seeded.snapshot.seededAt == "2026-11-02T09:14:00Z")
        try? FileManager.default.removeItem(at: seeded.fileURL.deletingLastPathComponent())
    }

    @Test func closeWritesPendingChangesWithPrivatePermissions() async throws {
        let parent = try TemporaryDirectory()
        defer { parent.remove() }
        let directory = parent.url.appending(path: "apps", directoryHint: .isDirectory)
        let time = VirtualTime()
        let store = ActivityStore(directory: directory, now: time.now, clock: NeverClock())
        await store.load()
        await store.recordUse(of: "com.example.notes", at: time.date)
        #expect(await store.hasPendingWrite)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        await store.close()
        #expect(!(await store.hasPendingWrite))

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let reopened = ActivityStore(directory: directory, now: time.now, clock: NeverClock())
        await reopened.load()
        #expect(reopened.snapshot.apps["com.example.notes"]?.useCount == 1)
    }

    @Test func changesAreWrittenAfterTheDelay() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let store = makeStore(directory, time: time, clock: VirtualClock(time: time))
        await store.load()
        await store.recordUse(of: "com.example.notes", at: time.date)
        let written = await eventually { FileManager.default.fileExists(atPath: store.fileURL.path) }
        #expect(written)
        #expect(await eventually { !(await store.hasPendingWrite) })
    }

    @Test func aFutureLastUseIsClampedOnLoad() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let start = time.date.timeIntervalSince1970
        // The file was written before the clock moved back by a day.
        let file = ActivityStore.FileContents(
            version: 1,
            seededAt: nil,
            apps: ["com.example.notes": ActivityEntry(frecency: 2, lastUsedAt: start + Self.day, useCount: 2)]
        )
        try JSONEncoder().encode(file).write(to: directory.url.appending(path: ActivityStore.fileName))
        let store = makeStore(directory, time: time)
        await store.load()
        let entry = try #require(store.snapshot.apps["com.example.notes"])
        #expect(entry.lastUsedAt == start)
        #expect(entry.frecency == 2)
        #expect(await store.hasPendingWrite)

        // 90 days later the entry expires instead of staying forever.
        time.advance(to: 90 * Self.day + 1)
        await store.recordUse(of: "com.example.mail", at: time.date)
        await store.close()
        let saved = try JSONDecoder().decode(
            ActivityStore.FileContents.self,
            from: Data(contentsOf: directory.url.appending(path: ActivityStore.fileName)))
        #expect(Set(saved.apps.keys) == ["com.example.mail"])
    }

    @Test func aUseAfterTheClockMovedBackIsNeverInTheFuture() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let time = VirtualTime()
        let store = makeStore(directory, time: time)
        await store.load()
        time.advance(to: Self.hour)
        await store.recordUse(of: "com.example.notes", at: time.date)
        time.advance(by: -2 * Self.hour)
        await store.recordUse(of: "com.example.notes", at: time.date)
        #expect(store.snapshot.apps["com.example.notes"]?.lastUsedAt == time.date.timeIntervalSince1970)
        #expect(store.snapshot.apps["com.example.notes"]?.useCount == 2)
        await store.merge(seed: [:], seededAt: "seeded")
        #expect(store.snapshot.apps["com.example.notes"]?.lastUsedAt == time.date.timeIntervalSince1970)
    }
}
