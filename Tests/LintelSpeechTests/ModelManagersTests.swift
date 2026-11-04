import Foundation
import Synchronization
import Testing
import os

@testable import LintelSpeech

/// Writes the fixture's files without a network and counts how many downloads overlap.
private final class CountingDownloader: FileDownloading {
    private let state = Mutex((active: 0, peak: 0, calls: 0))
    private let fixture: Fixture

    init(_ fixture: Fixture) { self.fixture = fixture }

    var peak: Int { state.withLock { $0.peak } }
    var calls: Int { state.withLock { $0.calls } }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int) -> Void) async throws {
        state.withLock {
            $0.active += 1
            $0.calls += 1
            $0.peak = max($0.peak, $0.active)
        }
        defer { state.withLock { $0.active -= 1 } }
        // Give a second caller every chance to run in between.
        for _ in 0..<20 { await Task.yield() }
        let data = url.lastPathComponent == "vocab.json" ? fixture.b : fixture.a
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        progress(data.count)
    }
}

@Suite struct ModelManagerRegistryTests {
    private func registry(_ downloader: CountingDownloader) -> ModelManagers {
        ModelManagers(factory: { directory, logger in
            ModelManager(directory: directory, downloader: downloader, availableSpace: { _ in .max }, logger: logger)
        })
    }

    @Test func oneManagerServesEveryClientOfADirectory() throws {
        let fixture = try Fixture()
        let registry = registry(CountingDownloader(fixture))
        let models = fixture.directory.url.appending(path: "Models", directoryHint: .isDirectory)
        let first = registry.manager(for: models)
        let same = registry.manager(for: fixture.directory.url.appending(path: "other/../Models"))
        let other = registry.manager(for: fixture.directory.url.appending(path: "llm"))
        #expect(first === same)
        #expect(first !== other)
    }

    @Test func theLoggerOfTheFirstCallerWinsAndLaterCallersGetTheSameManager() throws {
        let fixture = try Fixture()
        let created = Mutex(0)
        let registry = ModelManagers(factory: { directory, _ in
            created.withLock { $0 += 1 }
            return ModelManager(directory: directory)
        })
        let first = registry.manager(for: fixture.directory.url, logger: Logger(subsystem: "a", category: "one"))
        let second = registry.manager(for: fixture.directory.url, logger: Logger(subsystem: "b", category: "two"))
        #expect(first === second)
        #expect(created.withLock { $0 } == 1)
    }

    @Test func twoClientsInstallingTheSameModelDownloadItOnceAndLeaveAWholePackage() async throws {
        let fixture = try Fixture()
        let downloader = CountingDownloader(fixture)
        let registry = registry(downloader)
        let models = fixture.directory.url.appending(path: "Models", directoryHint: .isDirectory)
        let dictation = registry.manager(for: models)
        let meetings = registry.manager(for: models)

        async let one = dictation.install(fixture.package)
        async let two = meetings.install(fixture.package)
        let (first, second) = try await (one, two)

        #expect(first == second)
        #expect(downloader.peak == 1)
        // Two files, fetched by the first install; the second found the package complete.
        #expect(downloader.calls == 2)
        try await dictation.verify(folder: first, for: fixture.package)
        #expect(await meetings.location(of: fixture.package) == .installed(first))
        #expect(!FileManager.default.fileExists(atPath: models.appending(path: "fixture.partial").path))
    }

    @Test func installsAndRemovalsFromTwoClientsNeverLeaveAHalfPackage() async throws {
        let fixture = try Fixture()
        let downloader = CountingDownloader(fixture)
        let registry = registry(downloader)
        let models = fixture.directory.url.appending(path: "Models", directoryHint: .isDirectory)
        let dictation = registry.manager(for: models)
        let meetings = registry.manager(for: models)

        for _ in 0..<5 {
            async let install = dictation.install(fixture.package)
            async let removeOne: Void = meetings.delete(fixture.package)
            async let removeTwo: Void = dictation.delete(fixture.package)
            _ = try await (install, removeOne, removeTwo)
            switch await dictation.location(of: fixture.package) {
            case .installed(let folder): try await dictation.verify(folder: folder, for: fixture.package)
            case .missing: break
            case let other: Issue.record("Unexpected state \(other)")
            }
            #expect(!FileManager.default.fileExists(atPath: models.appending(path: "fixture.partial").path))
        }
        #expect(downloader.peak == 1)
    }
}

/// A downloader whose files wait for the test to open the gate.
private final class GatedDownloader: FileDownloading {
    private let fixture: Fixture
    let gate = Latch()
    private let started = Mutex(0)

    init(_ fixture: Fixture) { self.fixture = fixture }

    var downloads: Int { started.withLock { $0 } }

    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int) -> Void) async throws {
        started.withLock { $0 += 1 }
        await gate.wait()
        let data = url.lastPathComponent == "vocab.json" ? fixture.b : fixture.a
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        progress(data.count)
    }
}

@Suite struct ModelManagerQueueTests {
    private func manager(_ fixture: Fixture, _ downloader: GatedDownloader) -> ModelManager {
        ModelManager(
            directory: fixture.directory.url.appending(path: "Models", directoryHint: .isDirectory),
            downloader: downloader, availableSpace: { _ in .max })
    }

    @Test func aCancelledQueuedInstallThrowsAtOnceAndDoesNotBlockTheOthers() async throws {
        let fixture = try Fixture()
        let downloader = GatedDownloader(fixture)
        let manager = manager(fixture, downloader)
        let first = Task { try await manager.install(fixture.package) }
        await until { downloader.downloads == 1 }
        let queued = Task { try await manager.install(fixture.package) }
        let third = Task { try await manager.install(fixture.package) }
        await settle()
        queued.cancel()
        // Thrown while the first install is still running (the gate is closed).
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(downloader.downloads == 1)

        downloader.gate.open()
        let folder = try await first.value
        #expect(try await third.value == folder)
        try await manager.verify(folder: folder, for: fixture.package)
    }

    @Test func aQueuedDeleteRunsAfterTheInstallAndAfterItTheModelIsGone() async throws {
        let fixture = try Fixture()
        let downloader = GatedDownloader(fixture)
        let manager = manager(fixture, downloader)
        let install = Task { try await manager.install(fixture.package) }
        await until { downloader.downloads == 1 }
        let delete = Task { try await manager.delete(fixture.package) }
        await settle()
        // The delete waits: the package is not removed under the running install.
        #expect(downloader.downloads == 1)
        downloader.gate.open()
        let folder = try await install.value
        try await delete.value
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await manager.location(of: fixture.package) == .missing)
    }

    @Test func aCancelledWaiterDoesNotLoseTheTurnOfTheNextOne() async throws {
        let fixture = try Fixture()
        let downloader = GatedDownloader(fixture)
        let manager = manager(fixture, downloader)
        let install = Task { try await manager.install(fixture.package) }
        await until { downloader.downloads == 1 }
        let cancelled = Task { try await manager.delete(fixture.package) }
        await settle()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        downloader.gate.open()
        _ = try await install.value
        // The lock is free again: a later delete runs.
        try await manager.delete(fixture.package)
        #expect(await manager.location(of: fixture.package) == .missing)
    }
}
