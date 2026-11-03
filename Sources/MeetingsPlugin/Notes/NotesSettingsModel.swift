import Foundation
import Observation
import PounceSpeech

/// What the notes section of Settings → Meetings and the `meetings.setup` step show and do: the switch, the
/// built-in model (the catalog models this Mac has the memory for, their size, download with progress and
/// removal) and "Try it". The switch is written only when the user flips it.
@MainActor @Observable
final class NotesSettingsModel {
    enum TryState: Equatable {
        case idle
        case running
        case result(String)
        case failed
        case modelMissing
    }

    /// Automatic notes after each meeting. Never written until the user chooses.
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            settings.setNotesEnabled(enabled)
            Task { await service.refreshAvailability() }
        }
    }
    let models: [LLMModel]
    private(set) var model: LLMModel
    /// The stored model does not fit this Mac (or left the catalog): the default one is used instead.
    private(set) var wasReplaced: Bool
    private(set) var location = ModelLocation.missing
    private(set) var progress: ModelProgress?
    private(set) var errorMessage: String?
    private(set) var isInUse = false
    private(set) var tryState = TryState.idle

    @ObservationIgnored private let settings: MeetingsSettings
    @ObservationIgnored private let service: NotesService
    @ObservationIgnored private let manager: ModelManager
    @ObservationIgnored private let lease: LLMLease
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadGeneration = 0
    @ObservationIgnored private var tryTask: Task<Void, Never>?

    init(settings: MeetingsSettings, service: NotesService, manager: ModelManager, lease: LLMLease = .shared) {
        self.settings = settings
        self.service = service
        self.manager = manager
        self.lease = lease
        models = settings.offeredLLMModels
        model = settings.builtInLLMModel
        wasReplaced = settings.builtInLLMModelWasReplaced
        enabled = settings.notesEnabled
    }

    var isInstalled: Bool { location.folder != nil }
    var isDownloading: Bool { progress != nil }

    /// The GGUF file of the installed model.
    private var modelFile: URL? { location.folder.flatMap { model.fileURL(in: $0) } }

    func refresh() async {
        model = settings.builtInLLMModel
        wasReplaced = settings.builtInLLMModelWasReplaced
        location = await manager.location(of: model.package)
        if let file = modelFile {
            let leased = await lease.isInUse(modelID: file.path)
            isInUse = service.isBusy || leased
        } else {
            isInUse = false
        }
        await service.refreshAvailability()
    }

    // MARK: Model

    func choose(_ id: String) async {
        guard id != model.id, let chosen = models.first(where: { $0.id == id }) else { return }
        cancelDownload()
        settings.setBuiltInLLMModel(chosen)
        errorMessage = nil
        tryState = .idle
        await refresh()
    }

    func download() {
        guard downloadTask == nil else { return }
        errorMessage = nil
        let package = model.package
        progress = ModelProgress(bytesDone: 0, bytesTotal: package.totalBytes)
        downloadGeneration += 1
        let generation = downloadGeneration
        let manager = manager
        downloadTask = Task { [weak self] in
            do {
                _ = try await manager.install(package) { value in
                    Task { @MainActor in
                        guard let self, self.downloadGeneration == generation, self.downloadTask != nil else { return }
                        self.progress = value
                    }
                }
            } catch is CancellationError {
            } catch {
                self?.errorMessage = MeetingsModelMessages.message(for: error)
            }
            self?.progress = nil
            self?.downloadTask = nil
            await self?.refresh()
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    /// Resolves once a running download has ended (tests).
    func waitForDownload() async { await downloadTask?.value }

    /// Deletes the downloaded model, refused while a notes job or a dictation request uses it. The loaded
    /// copy that is only kept warm is freed first so the file is not open.
    func remove() async {
        guard let file = modelFile else { return }
        let lease = lease
        let path = file.path
        let leased = await lease.isInUse(modelID: path)
        if service.isBusy || leased {
            isInUse = true
            errorMessage = NotesMessages.modelInUse
            return
        }
        await lease.evictIdle()
        do {
            let package = model.package
            let service = service
            let removed = try await manager.delete(package) { @Sendable in
                if await lease.isInUse(modelID: path) { return true }
                return await service.isBusy
            }
            errorMessage = removed ? nil : NotesMessages.modelInUse
        } catch {
            errorMessage = MeetingsModelMessages.message(for: error)
        }
        tryState = .idle
        await refresh()
    }

    // MARK: Try it

    /// "Try it on an example": the notes of the bundled sample transcript, shown here and stored nowhere.
    func tryIt() {
        guard tryTask == nil, isInstalled else { return }
        tryState = .running
        let run = service.runSample()
        tryTask = Task { [weak self] in
            let outcome = await run.value
            guard let self else { return }
            switch outcome {
            case .notes(let markdown): tryState = .result(markdown)
            case .modelMissing: tryState = .modelMissing
            case .failed: tryState = .failed
            }
            tryTask = nil
        }
    }

    /// Resolves once "Try it" has ended (tests).
    func waitForTry() async { await tryTask?.value }
}

enum NotesMessages {
    static var writing: String {
        String(localized: "Writing notes…", comment: "Meeting window banner while the notes are being written")
    }

    /// "3 punkty bez pokrycia w nagraniu pominięto" (the String Catalog has the Polish plural forms).
    static func dropped(_ count: Int) -> String {
        String(
            localized: "\(count) points not backed by the recording were left out",
            comment: "Notes: how many points had no quote in the transcript and were left out")
    }

    static var partialNotice: String {
        String(
            localized: "These notes miss parts of the recording that could not be read.",
            comment: "Meeting library preview: notice above partial notes")
    }

    static var failedNotice: String {
        String(
            localized: "Writing the notes failed. The notes below are from an earlier run.",
            comment: "Meeting library preview: notice above older notes after a failed run")
    }

    static var modelInUse: String {
        String(
            localized: "The notes model is in use right now. Try again when the notes are written.",
            comment: "Meetings settings: the notes model cannot be removed while it is used")
    }
}
