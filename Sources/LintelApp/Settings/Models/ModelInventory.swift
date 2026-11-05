import Foundation
import LintelKit
import LintelSpeech

/// One package the catalog offers, as the Models pane lists it.
struct CatalogModel: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let kind: ModelKind
    let bytes: Int
    /// False for a language model this Mac does not have the memory for: listed (it may be installed), never
    /// offered for download.
    let canDownload: Bool
    /// The licence the catalog names for the package (`ModelPackage.license`); `nil` when it names none.
    let license: String?
    /// Memory the loaded model takes (`LLMModel.residentBytes`); `nil` when the catalog does not know it.
    let residentBytes: Int?

    init(
        id: String, title: String, kind: ModelKind, bytes: Int, canDownload: Bool = true, license: String? = nil,
        residentBytes: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.bytes = bytes
        self.canDownload = canDownload
        self.license = license
        self.residentBytes = residentBytes
    }
}

/// Where a package is in Lintel's own `Models/` folder.
enum InventoryState: Equatable, Sendable {
    case installed
    /// An interrupted download waits to be continued.
    case partial(bytes: Int)
    case missing
}

/// The Models pane's port onto the model files (spec `2026-11-04-lintel-main-window`, step 3.2). The real one,
/// `SharedModelInventory`, wraps `ModelManagers.shared` and the shared leases; tests give the pane a fake, so they
/// never touch `ModelManagers.shared`.
protocol ModelInventory: AnyObject, Sendable {
    /// Every package of every kind, in catalog order.
    var catalog: [CatalogModel] { get }
    func state(of id: String) async -> InventoryState
    func install(_ id: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws
    /// Checks the files and sums of a folder the user downloaded the package into by hand.
    func verify(folder: URL, for id: String) async throws
    /// `ModelManager.delete(_:unless:)`: `false` when `isInUse` said so and nothing was removed.
    func delete(_ id: String, unless isInUse: @escaping @Sendable () async -> Bool) async throws -> Bool
    /// The shell's own check: a speech lease holds the package resident with active leases, or an LLM lease is
    /// active on its file.
    func isLeased(_ id: String) async -> Bool
    /// Unloads an idle warm model of `kind` (`SpeechEngineLease.evictIdle()`, `LLMLease.evictIdle()`), so a
    /// removed model stops serving requests.
    func evictIdle(_ kind: ModelKind) async
}

/// The real inventory over `Models/speech`, `Models/llm` and `Models/diarization` (the folders the plugins use).
@MainActor
final class SharedModelInventory: ModelInventory {
    nonisolated let catalog: [CatalogModel]

    private let packages: [String: ModelPackage]
    private let kinds: [String: ModelKind]
    private let managers: [ModelKind: ModelManager]
    private let speechLease: SpeechEngineLease
    private let llmLease: LLMLease

    init(
        modelsDirectory: URL, managers registry: ModelManagers = .shared, speechLease: SpeechEngineLease = .shared,
        llmLease: LLMLease = .shared, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) {
        let fitting = Set(LLMModelCatalog.available(physicalMemory: physicalMemory).map(\.id))
        var catalog: [CatalogModel] = []
        var packages: [String: ModelPackage] = [:]
        var kinds: [String: ModelKind] = [:]
        func add(
            _ package: ModelPackage, _ kind: ModelKind, canDownload: Bool = true, residentBytes: Int? = nil
        ) {
            catalog.append(
                CatalogModel(
                    id: package.id, title: package.title, kind: kind, bytes: package.totalBytes,
                    canDownload: canDownload, license: package.license.isEmpty ? nil : package.license,
                    residentBytes: residentBytes))
            packages[package.id] = package
            kinds[package.id] = kind
        }
        for package in ModelCatalog.all { add(package, .speech) }
        for model in LLMModelCatalog.all {
            add(
                model.package, .llm,
                canDownload: fitting.contains(model.id) || model.id == LLMModelCatalog.defaultModel.id,
                residentBytes: model.residentBytes)
        }
        for package in ModelCatalog.diarization { add(package, .diarization) }
        self.catalog = catalog
        self.packages = packages
        self.kinds = kinds
        func manager(_ name: String) -> ModelManager {
            registry.manager(for: modelsDirectory.appending(path: name, directoryHint: .isDirectory))
        }
        managers = [.speech: manager("speech"), .llm: manager("llm"), .diarization: manager("diarization")]
        self.speechLease = speechLease
        self.llmLease = llmLease
    }

    private func lookup(_ id: String) -> (ModelPackage, ModelManager)? {
        guard let package = packages[id], let kind = kinds[id], let manager = managers[kind] else { return nil }
        return (package, manager)
    }

    /// The state of the downloaded copy only. A folder the user chose ("Choose Folder…") is not seen here:
    /// `ModelUsage` carries no folder and the contract stays as it is, so such a model reads "Not installed".
    /// The plugins therefore declare their speech usage required only while no folder is chosen, so a chosen
    /// folder never raises the "needed" banner or asks for a second download.
    func state(of id: String) async -> InventoryState {
        guard let (package, manager) = lookup(id) else { return .missing }
        switch await manager.location(of: package) {
        case .installed, .customFolder: return .installed
        case .partial(let bytes): return .partial(bytes: bytes)
        case .missing, .customFolderUnavailable: return .missing
        }
    }

    func install(_ id: String, progress: @escaping @Sendable (ModelProgress) -> Void) async throws {
        guard let (package, manager) = lookup(id) else { throw ModelError.notInstalled }
        try await manager.install(package, progress: progress)
    }

    func verify(folder: URL, for id: String) async throws {
        guard let (package, manager) = lookup(id) else { throw ModelError.notInstalled }
        try await manager.verify(folder: folder, for: package)
    }

    func delete(_ id: String, unless isInUse: @escaping @Sendable () async -> Bool) async throws -> Bool {
        guard let (package, manager) = lookup(id) else { return false }
        return try await manager.delete(package, unless: isInUse)
    }

    func isLeased(_ id: String) async -> Bool {
        switch kinds[id] {
        case .speech?:
            guard await speechLease.activeLeases > 0 else { return false }
            return await speechLease.residentKey?.modelID == id
        case .llm?:
            guard let model = LLMModelCatalog.model(id: id), let manager = managers[.llm],
                let folder = await manager.location(of: model.package).folder,
                let file = model.fileURL(in: folder)
            else { return false }
            return await llmLease.isInUse(modelID: file.path)
        default:
            return false
        }
    }

    func evictIdle(_ kind: ModelKind) async {
        switch kind {
        case .speech: await speechLease.evictIdle()
        case .llm: await llmLease.evictIdle()
        default: break
        }
    }
}
