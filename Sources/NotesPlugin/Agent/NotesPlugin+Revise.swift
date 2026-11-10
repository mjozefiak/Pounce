import Foundation
import LintelKit
import LintelSpeech

/// The agent's place in the plugin (spec step 6.2): the service, the notes model it runs on, and the Models pane's
/// view of it.
extension NotesPlugin {
    /// `Models/llm/`, shared with Dictation and Meetings: the same `ModelManager` as the pane's and Meetings'.
    var llmManager: ModelManager {
        ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(path: Self.llmDirectoryName, directoryHint: .isDirectory))
    }

    func makeReviseService() -> ReviseService {
        ReviseService(
            ReviseService.Dependencies(
                clock: RunClock(context.clock),
                model: { [weak self] in await self?.resolveReviseModel() }))
    }

    /// The model Notes runs on and the installed file of it: the stored choice while it is in the catalog, else the
    /// first installed catalog model (one rule, also for the settings key); `nil` when that model is not installed.
    func installedNotesModel() async -> (model: LLMModel, file: URL)? {
        let manager = llmManager
        var installed: [String: URL] = [:]
        for model in LLMModelCatalog.all {
            if let folder = await manager.location(of: model.package).folder, let file = model.fileURL(in: folder),
                FileManager.default.fileExists(atPath: file.path)
            {
                installed[model.id] = file
            }
        }
        let model = NotesSettings(context.settings).builtInLLMModel(installedIDs: Set(installed.keys))
        guard let file = installed[model.id] else { return nil }
        return (model, file)
    }

    func resolveReviseModel() async -> ResolvedReviseModel? {
        guard let (model, file) = await installedNotesModel() else { return nil }
        return ResolvedReviseModel(id: model.id, leasing: LeasedReviseModel(modelURL: file))
    }

    /// The Models pane's `ModelUsage` of the notes model: in use while a run is going on (also while it waits for
    /// the model or between two leases) or while any lease holds the file; a removal reserves the model, so a new
    /// run does not start while the file is deleted.
    var notesModelUsage: ModelUsage {
        let current = NotesSettings(context.settings).builtInLLMModel(installedIDs: installedModelIDs)
        let service = reviseService
        let manager = llmManager
        return ModelUsage(
            packageID: current.id, kind: .llm,
            role: LocalizedStringResource("Notes", comment: "Models pane: what Notes uses the language model for"),
            isRequired: false, isSelected: true,
            isInUse: {
                await NotesModelInUse(service: service) {
                    guard let folder = await manager.location(of: current.package).folder,
                        let file = current.fileURL(in: folder)
                    else { return false }
                    return await LLMLease.shared.isInUse(modelID: file.path)
                }()
            },
            reserveRemoval: { service.reserveRemoval() })
    }
}

/// `ModelUsage.isInUse` of the notes model: `runActive || lease.isInUse(modelID: path)` (spec step 6.2). Meetings asks
/// the same lease with the same path (`MeetingsPlugin.modelUsage`), so a removal is refused while either holds it.
struct NotesModelInUse {
    let service: ReviseService
    let leaseHoldsFile: @Sendable () async -> Bool

    init(service: ReviseService, leaseHoldsFile: @escaping @Sendable () async -> Bool) {
        self.service = service
        self.leaseHoldsFile = leaseHoldsFile
    }

    @MainActor
    func callAsFunction() async -> Bool {
        if service.isRunActive { return true }
        return await leaseHoldsFile()
    }
}

extension NotesWorkspaceModel.Environment {
    /// Wires "Revise with N comments" and "Ask agent" to the service: the request is built on the layer's writer
    /// (the registry's one writer per document) and the store.
    @MainActor
    mutating func installRevise(
        service: ReviseService, store: @escaping @MainActor @Sendable () -> NotesStore?,
        registry: NoteDocumentRegistry, clock: any Clock<Duration>, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        revise = { call in
            guard let opened = store(), case .live(let key) = call.item,
                let document = try? opened.liveDocument(key: key, layer: call.layer)
            else { return .nothingToRevise(skipped: []) }
            let writer = registry.writer(for: .live(key, layer: call.layer), item: call.item) {
                RevisionWriter(store: opened, target: .existing(docID: document.id), clock: clock, now: now)
            }
            return await service.start(
                ReviseRequest(item: call.item, writer: writer, lock: call.lock, store: opened, threads: call.threads))
        }
        cancelRevise = { service.cancel($0) }
        isReviseQueued = { service.isQueued($0, thread: $1) }
    }
}
