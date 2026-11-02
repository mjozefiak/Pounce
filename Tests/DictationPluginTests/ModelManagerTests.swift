import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import DictationPlugin

/// A `URLProtocol` that answers from a table keyed by URL path, so tests never touch the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case body(Data, status: Int = 200, failAfter: Int? = nil)
        case redirect(URL)
        case status(Int)
    }

    struct Seen: Sendable {
        let path: String
        let range: String?
    }

    nonisolated(unsafe) private static let state = Mutex<(replies: [String: @Sendable (Seen) -> Reply], seen: [Seen])>(
        ([:], []))

    static func register(path: String, _ reply: @escaping @Sendable (Seen) -> Reply) {
        state.withLock { $0.replies[path] = reply }
    }

    static func requests(forPathPrefix prefix: String) -> [Seen] {
        state.withLock { $0.seen.filter { $0.path.hasPrefix(prefix) } }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let seen = Seen(path: url.path, range: request.value(forHTTPHeaderField: "Range"))
        let reply = Self.state.withLock { state -> (@Sendable (Seen) -> Reply)? in
            state.seen.append(seen)
            return state.replies[url.path]
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        switch reply(seen) {
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .body(let data, let status, let failAfter):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let failAfter {
                client?.urlProtocol(self, didLoad: data.prefix(failAfter))
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A tiny package of two files (one in a sub folder) on a repository name unique to the test.
struct Fixture {
    let repository = "test/\(UUID().uuidString.lowercased())"
    let a = Data(repeating: 0x41, count: 100)
    let b = Data("second file, a little longer than the first".utf8)
    let package: ModelPackage
    let directory: TemporaryDirectory
    var prefix: String { "/" + repository }

    init() throws {
        directory = try TemporaryDirectory()
        let a = a
        let b = b
        package = ModelPackage(
            id: "fixture", title: "Fixture", license: "MIT", attribution: "",
            sources: [
                ModelSource(
                    repository: repository, revision: "rev", into: "",
                    files: [
                        ModelFile(path: "Model.mlmodelc/weights/weight.bin", size: a.count, sha256: sha(a)),
                        ModelFile(path: "vocab.json", size: b.count, sha256: sha(b)),
                    ])
            ])
    }

    func manager(space: Int = .max) -> ModelManager {
        ModelManager(
            directory: directory.url.appending(path: "Models", directoryHint: .isDirectory),
            downloader: SessionDownloader(makeConfiguration: { StubProtocol.configuration() }),
            availableSpace: { _ in space })
    }

    func serve(
        a replyA: (@Sendable (StubProtocol.Seen) -> StubProtocol.Reply)? = nil,
        b replyB: (@Sendable (StubProtocol.Seen) -> StubProtocol.Reply)? = nil
    ) {
        let a = a
        let b = b
        StubProtocol.register(
            path: prefix + "/resolve/rev/Model.mlmodelc/weights/weight.bin", replyA ?? { _ in .body(a) })
        StubProtocol.register(path: prefix + "/resolve/rev/vocab.json", replyB ?? { _ in .body(b) })
    }
}

@Suite struct ModelManagerTests {
    @Test func downloadsVerifiesAndMovesIntoPlace() async throws {
        let fixture = try Fixture()
        fixture.serve()
        let manager = fixture.manager()
        let last = Mutex(ModelProgress(bytesDone: 0, bytesTotal: 0))
        let folder = try await manager.install(fixture.package) { value in last.withLock { $0 = value } }

        #expect(folder.lastPathComponent == "fixture")
        #expect(try Data(contentsOf: folder.appending(path: "Model.mlmodelc/weights/weight.bin")) == fixture.a)
        #expect(try Data(contentsOf: folder.appending(path: "vocab.json")) == fixture.b)
        #expect(await manager.location(of: fixture.package) == .installed(folder))
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.deletingLastPathComponent().appending(path: "fixture.partial").path))
        #expect(last.withLock { $0.fraction } == 1)
    }

    @Test func aWrongChecksumDeletesTheFileAndInstallsNothing() async throws {
        let fixture = try Fixture()
        fixture.serve(b: { _ in .body(Data(repeating: 0x5A, count: 43)) })
        let manager = fixture.manager()
        await #expect(throws: ModelError.checksumMismatch(path: "vocab.json")) {
            try await manager.install(fixture.package)
        }
        let models = fixture.directory.url.appending(path: "Models")
        #expect(!FileManager.default.fileExists(atPath: models.appending(path: "fixture").path))
        #expect(!FileManager.default.fileExists(atPath: models.appending(path: "fixture.partial/vocab.json.part").path))
        // The good file stays for the next attempt.
        #expect(
            FileManager.default.fileExists(
                atPath: models.appending(path: "fixture.partial/Model.mlmodelc/weights/weight.bin").path))
        #expect(await manager.location(of: fixture.package) != .missing)
    }

    @Test func aLeftoverPartialFileResumesWithARangeRequest() async throws {
        let fixture = try Fixture()
        let a = fixture.a
        fixture.serve(a: { _ in .body(a.dropFirst(40), status: 206) })
        // What an interrupted download leaves behind: the first 40 bytes of the first file.
        let weights = fixture.directory.url.appending(
            path: "Models/fixture.partial/Model.mlmodelc/weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try a.prefix(40).write(to: weights.appending(path: "weight.bin.part"))
        let manager = fixture.manager()
        #expect(await manager.location(of: fixture.package) == .partial(bytes: 40))

        let folder = try await manager.install(fixture.package)
        #expect(try Data(contentsOf: folder.appending(path: "Model.mlmodelc/weights/weight.bin")) == fixture.a)
        let requests = StubProtocol.requests(forPathPrefix: fixture.prefix + "/resolve/rev/Model.mlmodelc")
        #expect(requests.map(\.range) == ["bytes=40-"])
    }

    @Test func aDroppedConnectionFailsTheInstallAndInstallsNothing() async throws {
        let fixture = try Fixture()
        let a = fixture.a
        fixture.serve(a: { _ in .body(a, failAfter: 40) })
        let manager = fixture.manager()
        await #expect(throws: (any Error).self) { try await manager.install(fixture.package) }
        #expect(await manager.location(of: fixture.package).folder == nil)
    }

    @Test func aServerThatIgnoresTheRangeRestartsTheFile() async throws {
        let fixture = try Fixture()
        let a = fixture.a
        fixture.serve(a: { _ in .body(a) })
        let weights = fixture.directory.url.appending(
            path: "Models/fixture.partial/Model.mlmodelc/weights", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try a.prefix(30).write(to: weights.appending(path: "weight.bin.part"))
        let folder = try await fixture.manager().install(fixture.package)
        #expect(try Data(contentsOf: folder.appending(path: "Model.mlmodelc/weights/weight.bin")) == fixture.a)
    }

    @Test func notEnoughSpaceFailsBeforeAnyRequest() async throws {
        let fixture = try Fixture()
        fixture.serve()
        let manager = fixture.manager(space: 10)
        let needed = fixture.package.totalBytes + fixture.package.totalBytes / 10
        await #expect(throws: ModelError.insufficientSpace(needed: needed, available: 10)) {
            try await manager.install(fixture.package)
        }
        #expect(StubProtocol.requests(forPathPrefix: fixture.prefix).isEmpty)
    }

    @Test func aRedirectToAnAllowedHostIsFollowed() async throws {
        let fixture = try Fixture()
        let b = fixture.b
        fixture.serve()
        StubProtocol.register(path: fixture.prefix + "/resolve/rev/vocab.json") { _ in
            .redirect(URL(string: "https://cdn-lfs-us-1.hf.co\(fixture.prefix)/blob")!)
        }
        StubProtocol.register(path: fixture.prefix + "/blob") { _ in .body(b) }
        let folder = try await fixture.manager().install(fixture.package)
        #expect(try Data(contentsOf: folder.appending(path: "vocab.json")) == fixture.b)
    }

    @Test func aRedirectOutsideTheListAbortsTheDownload() async throws {
        let fixture = try Fixture()
        fixture.serve()
        StubProtocol.register(path: fixture.prefix + "/resolve/rev/vocab.json") { _ in
            .redirect(URL(string: "https://evil.example.com/vocab.json")!)
        }
        let manager = fixture.manager()
        await #expect(throws: ModelError.disallowedHost("evil.example.com")) {
            try await manager.install(fixture.package)
        }
        #expect(await manager.location(of: fixture.package) != .installed(fixture.directory.url))
    }

    @Test func aRedirectToPlainHTTPAbortsTheDownload() async throws {
        let fixture = try Fixture()
        fixture.serve()
        StubProtocol.register(path: fixture.prefix + "/resolve/rev/vocab.json") { _ in
            .redirect(URL(string: "http://cdn-lfs.hf.co/vocab.json")!)
        }
        await #expect(throws: ModelError.disallowedHost("cdn-lfs.hf.co")) {
            try await fixture.manager().install(fixture.package)
        }
    }

    @Test func anHTTPErrorFailsTheDownload() async throws {
        let fixture = try Fixture()
        fixture.serve(a: { _ in .status(500) })
        await #expect(throws: ModelError.httpStatus(500)) {
            try await fixture.manager().install(fixture.package)
        }
    }

    @Test func downloadHostsAreTheHuggingFaceAllowList() {
        for host in [
            "huggingface.co", "cdn-lfs.hf.co", "cdn-lfs-us-1.hf.co", "cas-bridge.xethub.hf.co", "HuggingFace.co",
        ] {
            #expect(ModelCatalog.isAllowedDownloadHost(host), "\(host)")
        }
        for host in [
            "example.com", "hf.co", "evil-huggingface.co", "huggingface.co.evil.com", "cdn-lfs.hf.co.evil.com",
            "cdn-lfs-.evil.com", "",
        ] {
            #expect(!ModelCatalog.isAllowedDownloadHost(host), "\(host)")
        }
    }

    @Test func cancellingKeepsThePartialFolder() async throws {
        let fixture = try Fixture()
        fixture.serve()
        let manager = fixture.manager()
        let task = Task { try await manager.install(fixture.package) }
        task.cancel()
        _ = try? await task.value
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.url.appending(path: "Models/fixture").path))
    }
}

@Suite struct ModelFolderTests {
    private func writeFixtureFiles(_ fixture: Fixture, to folder: URL) throws {
        let weights = folder.appending(path: "Model.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try fixture.a.write(to: weights.appending(path: "weight.bin"))
        try fixture.b.write(to: folder.appending(path: "vocab.json"))
    }

    @Test func aHandDownloadedFolderIsVerifiedWithoutCopying() async throws {
        let fixture = try Fixture()
        let folder = fixture.directory.url.appending(path: "mine", directoryHint: .isDirectory)
        try writeFixtureFiles(fixture, to: folder)
        let manager = fixture.manager()
        try await manager.verify(folder: folder, for: fixture.package)
        #expect(await manager.location(of: fixture.package, customFolder: folder) == .customFolder(folder))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.url.appending(path: "Models/fixture").path))
    }

    @Test func missingFilesAndWrongSumsAreReported() async throws {
        let fixture = try Fixture()
        let folder = fixture.directory.url.appending(path: "mine", directoryHint: .isDirectory)
        try writeFixtureFiles(fixture, to: folder)
        try FileManager.default.removeItem(at: folder.appending(path: "vocab.json"))
        let manager = fixture.manager()
        await #expect(throws: ModelError.folderIncomplete(missing: ["vocab.json"])) {
            try await manager.verify(folder: folder, for: fixture.package)
        }
        try Data(repeating: 0x42, count: fixture.b.count).write(to: folder.appending(path: "vocab.json"))
        await #expect(throws: ModelError.checksumMismatch(path: "vocab.json")) {
            try await manager.verify(folder: folder, for: fixture.package)
        }
    }

    @Test func aVanishedFolderIsUnavailableAndNothingIsDownloaded() async throws {
        let fixture = try Fixture()
        fixture.serve()
        let gone = URL(filePath: "/Volumes/unplugged/model")
        let manager = fixture.manager()
        #expect(await manager.location(of: fixture.package, customFolder: gone) == .customFolderUnavailable(gone))
        #expect(StubProtocol.requests(forPathPrefix: fixture.prefix).isEmpty)
    }

    @Test func deleteRemovesTheDownloadButNeverTheUsersFolder() async throws {
        let fixture = try Fixture()
        fixture.serve()
        let manager = fixture.manager()
        try await manager.install(fixture.package)
        let folder = fixture.directory.url.appending(path: "mine", directoryHint: .isDirectory)
        try writeFixtureFiles(fixture, to: folder)
        try await manager.delete(fixture.package)
        #expect(await manager.location(of: fixture.package) == .missing)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "vocab.json").path))
    }

    @Test func theRealCatalogIsConsistent() {
        let package = ModelCatalog.parakeetUltra
        #expect(package.totalBytes > 600_000_000 && package.totalBytes < 700_000_000)
        for entry in package.files {
            #expect(entry.file.sha256.count == 64)
            #expect(entry.source.url(for: entry.file)?.host == "huggingface.co")
            #expect(entry.source.url(for: entry.file)?.scheme == "https")
        }
        let paths = package.files.map { package.relativePath(of: $0.file, in: $0.source) }
        #expect(Set(paths).count == paths.count)
        // What FluidAudio's `.ultra` loader reads, and the VAD model.
        for required in [
            "Preprocessor.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin", "Decoder.mlmodelc/model.mil",
            "JointDecisionv3.mlmodelc/model.mil", "parakeet_vocab.json",
            "vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/weights/weight.bin",
        ] {
            #expect(paths.contains(required), "\(required)")
        }
    }
}

/// Manual check of step 1.3: one real download of Parakeet Ultra from Hugging Face (about 630 MB), so the
/// catalog's checksums and the hosts of the real redirects are confirmed. Off by default; run with
/// `POUNCE_DICTATION_DOWNLOAD=/path/to/Models swift test --filter RealDownloadTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POUNCE_DICTATION_DOWNLOAD"] != nil))
struct RealDownloadTests {
    @Test func downloadsTheRealParakeetUltraPackage() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["POUNCE_DICTATION_DOWNLOAD"])
        let manager = ModelManager(directory: URL(filePath: path, directoryHint: .isDirectory))
        let folder = try await manager.install(ModelCatalog.parakeetUltra)
        #expect(await manager.location(of: ModelCatalog.parakeetUltra) == .installed(folder))
        try await manager.verify(folder: folder, for: ModelCatalog.parakeetUltra)
    }
}
