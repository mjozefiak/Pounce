import Foundation
import Synchronization
import Testing

@testable import PounceSpeech

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
