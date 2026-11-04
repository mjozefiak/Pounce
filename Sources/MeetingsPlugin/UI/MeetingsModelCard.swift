import Foundation
import LintelSpeech
import Observation

/// One model package on a settings card: where it is, download with progress, a folder the user points to,
/// and removal. Used for the speech model and the diarization model. `Remove` is refused while a session
/// holds the model (`usage`), both in the button's state and again when the action runs.
@MainActor @Observable
final class MeetingsModelCardModel {
    private(set) var package: ModelPackage
    private(set) var location = ModelLocation.missing
    private(set) var progress: ModelProgress?
    private(set) var errorMessage: String?
    private(set) var isVerifying = false
    /// The last answer of `usage`; refreshed with the card and before every removal.
    private(set) var isInUse = false

    @ObservationIgnored private let manager: ModelManager
    @ObservationIgnored private let customFolder: () -> URL?
    @ObservationIgnored private let setCustomFolder: (URL?) -> Void
    @ObservationIgnored private let pickFolder: @MainActor () -> URL?
    @ObservationIgnored private let usage: MeetingsModelUsage
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Tells a progress report of the running download from a late one of an earlier download.
    @ObservationIgnored private var downloadGeneration = 0

    init(
        package: ModelPackage, manager: ModelManager, usage: MeetingsModelUsage, customFolder: @escaping () -> URL?,
        setCustomFolder: @escaping (URL?) -> Void, pickFolder: @escaping @MainActor () -> URL?
    ) {
        self.package = package
        self.manager = manager
        self.usage = usage
        self.customFolder = customFolder
        self.setCustomFolder = setCustomFolder
        self.pickFolder = pickFolder
    }

    var isDownloading: Bool { progress != nil }
    var isInstalled: Bool { location.folder != nil }

    /// Shows another package (the engine picker of the speech card).
    func use(_ package: ModelPackage) {
        guard package.id != self.package.id else { return }
        cancelDownload()
        self.package = package
        errorMessage = nil
        Task { await refresh() }
    }

    func refresh() async {
        location = await manager.location(of: package, customFolder: customFolder())
        isInUse = await usage.isInUse(package)
    }

    func download() {
        guard downloadTask == nil else { return }
        errorMessage = nil
        progress = ModelProgress(bytesDone: 0, bytesTotal: package.totalBytes)
        downloadGeneration += 1
        let generation = downloadGeneration
        let package = package
        let manager = manager
        downloadTask = Task { [weak self] in
            do {
                try await manager.install(package) { value in
                    Task { @MainActor in
                        // A report that arrives after the download ended must not bring the bar back.
                        guard let self, self.downloadGeneration == generation, self.downloadTask != nil else { return }
                        self.progress = value
                    }
                }
                self?.setCustomFolder(nil)
            } catch is CancellationError {
            } catch {
                self?.errorMessage = MeetingsModelMessages.message(for: error)
            }
            self?.progress = nil
            self?.downloadTask = nil
            await self?.refresh()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Resolves once a running download has ended (tests).
    func waitForDownload() async {
        await downloadTask?.value
    }

    /// "Choose Folder…": checks the files and sums of a model the user downloaded by hand. One check at a
    /// time; a result that arrives after the card shows another package is dropped.
    func chooseFolder() async {
        guard !isVerifying, let folder = pickFolder() else { return }
        let chosenFor = package.id
        errorMessage = nil
        isVerifying = true
        do {
            try await manager.verify(folder: folder, for: package)
            if package.id == chosenFor { setCustomFolder(folder) }
        } catch {
            if package.id == chosenFor { errorMessage = MeetingsModelMessages.message(for: error) }
        }
        isVerifying = false
        await refresh()
    }

    /// The folder to load the model from, checked now. The load path (step 1.10) must use this and not the
    /// stored setting: a folder the user chose earlier can have been moved, emptied or changed since.
    func loadableFolder() async -> URL? {
        await manager.location(of: package, customFolder: customFolder()).folder
    }

    /// Goes back to the downloaded model.
    func useDownloadedModel() async {
        setCustomFolder(nil)
        await refresh()
    }

    /// Deletes the downloaded model (never the user's own folder). Refused while a session holds it: asked
    /// here for the message, and again by the manager right before the files go. A reservation on `usage`
    /// keeps a new session from starting in between.
    func removeModel() async {
        isInUse = await usage.isInUse(package)
        guard !isInUse else {
            errorMessage = MeetingsModelMessages.inUse
            return
        }
        let release = usage.reserveRemoval()
        defer { release() }
        let package = package
        let usage = usage
        do {
            if try await manager.delete(package, unless: { await usage.isInUse(package) }) {
                errorMessage = nil
            } else {
                errorMessage = MeetingsModelMessages.inUse
            }
        } catch {
            errorMessage = MeetingsModelMessages.message(for: error)
        }
        await refresh()
    }
}

enum MeetingsModelMessages {
    static var inUse: String {
        String(
            localized: "The model is in use by a meeting or dictation. Remove it when they have finished.",
            comment: "Meetings settings: the model cannot be removed while it is in use")
    }

    static func message(for error: Error) -> String {
        guard let error = error as? ModelError else {
            return String(
                localized: "The download did not finish. Check the connection and try again.",
                comment: "Dictation settings error after a failed download")
        }
        switch error {
        case .insufficientSpace(let needed, _):
            let size = ByteCountFormatter.string(fromByteCount: Int64(needed), countStyle: .file)
            return String(
                localized: "Not enough free space. The model needs \(size).",
                comment: "Dictation settings error when the disk is too full")
        case .checksumMismatch, .sizeMismatch:
            return String(
                localized: "A file does not match the expected checksum, so it was not used.",
                comment: "Dictation settings error after a failed checksum")
        case .disallowedHost, .httpStatus:
            return String(
                localized: "The download was refused by the server. Try again later.",
                comment: "Dictation settings error after the download server answered with an error")
        case .folderIncomplete(let missing):
            return String(
                localized: "This folder is missing \(missing.count) of the model's files.",
                comment: "Dictation settings error when a chosen model folder is incomplete")
        case .notInstalled:
            return String(localized: "The model is not installed.", comment: "Dictation settings error")
        }
    }
}
