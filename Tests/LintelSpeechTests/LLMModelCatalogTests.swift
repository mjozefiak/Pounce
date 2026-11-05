import Foundation
import Testing

@testable import LintelSpeech

@Suite struct LLMModelCatalogTests {
    @Test func everyModelIsOnePinnedVerifiedGGUFFromAllowedHosts() throws {
        #expect(Set(LLMModelCatalog.all.map(\.id)).count == LLMModelCatalog.all.count)
        for model in LLMModelCatalog.all {
            let entries = model.package.files
            #expect(entries.count == 1, "\(model.id)")
            let entry = try #require(entries.first)
            #expect(entry.file.path.hasSuffix(".gguf"))
            #expect(entry.file.size > 1_000_000_000)
            #expect(entry.file.sha256.count == 64 && entry.file.sha256.allSatisfy(\.isHexDigit))
            #expect(entry.source.revision.count == 40 && entry.source.revision.allSatisfy(\.isHexDigit))
            let url = try #require(entry.source.url(for: entry.file))
            #expect(url.scheme == "https")
            #expect(ModelCatalog.isAllowedDownloadHost(try #require(url.host)))
            #expect(url.path.contains("/resolve/\(entry.source.revision)/"))
            #expect(model.package.license == "Apache-2.0")
            #expect(model.residentBytes > entry.file.size)
        }
    }

    @Test func theDefaultIsTheSmallModelAndTheLargeOneNeedsMemory() {
        #expect(LLMModelCatalog.defaultModel.id == LLMModelCatalog.qwen3Small.id)
        let sixteen = UInt64(16) << 30
        let sixtyFour = UInt64(64) << 30
        #expect(LLMModelCatalog.available(physicalMemory: sixteen) == [LLMModelCatalog.qwen3Small])
        #expect(LLMModelCatalog.available(physicalMemory: sixtyFour) == LLMModelCatalog.all)
        #expect(LLMModelCatalog.available(physicalMemory: UInt64(4) << 30).isEmpty)
    }

    @Test func modelsAreLookedUpById() {
        #expect(LLMModelCatalog.model(id: LLMModelCatalog.qwen3Large.id) == LLMModelCatalog.qwen3Large)
        #expect(LLMModelCatalog.model(id: "nope") == nil)
    }

    @Test func speechAndFormattingModelsNeverShareAnId() {
        let speech = Set(ModelCatalog.all.map(\.id))
        #expect(speech.isDisjoint(with: Set(LLMModelCatalog.all.map(\.id))))
    }
}

/// A one-file GGUF-shaped package goes through the same download path as a speech model.
@Suite struct LLMModelInstallTests {
    private func fixture() throws -> (model: LLMModel, content: Data, repository: String, directory: TemporaryDirectory)
    {
        let content = Data((0..<5000).map { UInt8($0 % 251) })
        let repository = "test/\(UUID().uuidString.lowercased())"
        let model = LLMModel(
            package: ModelPackage(
                id: "llm-fixture", title: "Fixture", license: "Apache-2.0", attribution: "",
                sources: [
                    ModelSource(
                        repository: repository, revision: "rev", into: "",
                        files: [ModelFile(path: "fixture-Q4_K_M.gguf", size: content.count, sha256: sha(content))])
                ]),
            residentBytes: 1, minimumMemoryBytes: 0)
        return (model, content, repository, try TemporaryDirectory())
    }

    private func manager(in directory: TemporaryDirectory, space: Int = .max) -> ModelManager {
        ModelManager(
            directory: directory.url.appending(path: "llm", directoryHint: .isDirectory),
            downloader: SessionDownloader(makeConfiguration: { StubProtocol.configuration() }),
            availableSpace: { _ in space })
    }

    @Test func aModelInstallsIntoTheLLMFolderAndTheRuntimeFindsItsFile() async throws {
        let (model, content, repository, directory) = try fixture()
        StubProtocol.register(path: "/\(repository)/resolve/rev/fixture-Q4_K_M.gguf") { _ in .body(content) }
        let manager = manager(in: directory)
        let folder = try await manager.install(model.package)

        #expect(folder.deletingLastPathComponent().lastPathComponent == "llm")
        let file = try #require(model.fileURL(in: folder))
        #expect(try Data(contentsOf: file) == content)
        #expect(await manager.location(of: model.package) == .installed(folder))
        withExtendedLifetime(directory) {}
    }

    @Test func aWrongChecksumInstallsNothing() async throws {
        let (model, _, repository, directory) = try fixture()
        StubProtocol.register(path: "/\(repository)/resolve/rev/fixture-Q4_K_M.gguf") { _ in
            .body(Data(repeating: 0, count: 5000))
        }
        let manager = manager(in: directory)
        await #expect(throws: ModelError.self) { try await manager.install(model.package) }
        #expect(await manager.location(of: model.package).folder == nil)
        withExtendedLifetime(directory) {}
    }

    @Test func tooLittleSpaceIsRefusedBeforeDownloading() async throws {
        let (model, _, repository, directory) = try fixture()
        let manager = manager(in: directory, space: 100)
        await #expect(throws: ModelError.self) { try await manager.install(model.package) }
        #expect(StubProtocol.requests(forPathPrefix: "/\(repository)").isEmpty)
        withExtendedLifetime(directory) {}
    }

    @Test func deletingRemovesTheFile() async throws {
        let (model, content, repository, directory) = try fixture()
        StubProtocol.register(path: "/\(repository)/resolve/rev/fixture-Q4_K_M.gguf") { _ in .body(content) }
        let manager = manager(in: directory)
        let folder = try await manager.install(model.package)
        try await manager.delete(model.package)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(await manager.location(of: model.package) == .missing)
        withExtendedLifetime(directory) {}
    }

}

/// Manual check of step 4.2: one real download of the default formatting model (about 2.3 GB), so the catalog's
/// size and SHA-256 and the hosts of the real redirects are confirmed; then the downloaded file is loaded by
/// `LlamaRuntime`. Off by default; run with
/// `LINTEL_LLM_DOWNLOAD=/path/to/llm swift test --filter RealLLMDownloadTests`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_LLM_DOWNLOAD"] != nil))
struct RealLLMDownloadTests {
    @Test func downloadsAndLoadsTheDefaultModel() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LINTEL_LLM_DOWNLOAD"])
        let model = LLMModelCatalog.defaultModel
        let manager = ModelManager(directory: URL(filePath: path, directoryHint: .isDirectory))
        let folder = try await manager.install(model.package)
        #expect(await manager.location(of: model.package) == .installed(folder))
        try await manager.verify(folder: folder, for: model.package)
        let file = try #require(model.fileURL(in: folder))
        let runtime = LlamaRuntime()
        try await runtime.load(modelAt: file)
        #expect(await runtime.isLoaded)
        await runtime.unload()
    }
}
