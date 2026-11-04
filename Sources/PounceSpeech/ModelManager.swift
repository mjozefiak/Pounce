import CryptoKit
import Foundation
import os

/// Where a speech model package is, as far as the settings and the disk say.
public enum ModelLocation: Equatable, Sendable {
    /// Downloaded by Pounce into `Plugins/dictation/Models/<id>/`.
    case installed(URL)
    /// The folder the user pointed at (never copied).
    case customFolder(URL)
    /// The user's folder is gone (an unmounted disk): nothing is downloaded silently.
    case customFolderUnavailable(URL)
    /// An interrupted download waits in `<id>.partial/`.
    case partial(bytes: Int)
    case missing

    public var folder: URL? {
        switch self {
        case .installed(let url), .customFolder(let url): url
        default: nil
        }
    }
}

public struct ModelProgress: Equatable, Sendable {
    public var bytesDone: Int
    public var bytesTotal: Int

    public init(bytesDone: Int, bytesTotal: Int) {
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
    }

    public var fraction: Double { bytesTotal == 0 ? 0 : min(1, Double(bytesDone) / Double(bytesTotal)) }
}

/// Downloads, verifies, locates and deletes model packages under one folder of the shared `Models/` folder. It is the
/// only thing that fetches model files; the engines load from the folder it returns and never download.
///
/// A download goes into `<id>.partial/`, every file is checked against the catalog's SHA-256, and the folder
/// is renamed to `<id>/` only when all of them match. A failed file is deleted; the rest stay, so the next
/// attempt continues instead of starting over.
public actor ModelManager {
    private let directory: URL
    private let downloader: any FileDownloading
    private let availableSpace: @Sendable (URL) -> Int
    private let logger: Logger
    /// Installs and deletions run one at a time: the actor is re-entered while a download awaits, and two of
    /// them on one package would write the same `.partial` folder.
    private var exclusiveBusy = false
    private var exclusiveWaiters: [(id: Int, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextWaiterID = 0

    /// - Parameters:
    ///   - directory: the folder the packages live in.
    ///   - availableSpace: free bytes on the volume of a URL; tests replace it.
    ///   - logger: the caller's logger, so the messages carry the caller's category.
    public init(
        directory: URL,
        downloader: any FileDownloading = SessionDownloader(),
        availableSpace: @escaping @Sendable (URL) -> Int = ModelManager.systemAvailableSpace,
        logger: Logger = Logger(subsystem: "app.pounce", category: "speech")
    ) {
        self.directory = directory
        self.downloader = downloader
        self.availableSpace = availableSpace
        self.logger = logger
    }

    public nonisolated static func systemAvailableSpace(_ url: URL) -> Int {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    private func installedFolder(_ package: ModelPackage) -> URL {
        directory.appending(path: package.id, directoryHint: .isDirectory)
    }

    private func partialFolder(_ package: ModelPackage) -> URL {
        directory.appending(path: package.id + ".partial", directoryHint: .isDirectory)
    }

    // MARK: Location

    /// The folder to load `package` from, preferring the user's own folder when the settings name one.
    /// This is a quick check (files exist with the right sizes); checksums run when the model is installed or
    /// the folder is chosen.
    public func location(of package: ModelPackage, customFolder: URL? = nil) -> ModelLocation {
        if let customFolder {
            return isComplete(package, in: customFolder)
                ? .customFolder(customFolder) : .customFolderUnavailable(customFolder)
        }
        let installed = installedFolder(package)
        if isComplete(package, in: installed) {
            return .installed(installed)
        }
        let bytes = partialBytes(package)
        return bytes > 0 ? .partial(bytes: bytes) : .missing
    }

    /// Whether every file of the package exists in `folder` with its expected size.
    private func isComplete(_ package: ModelPackage, in folder: URL) -> Bool {
        missingFiles(package, in: folder).isEmpty
    }

    private func missingFiles(_ package: ModelPackage, in folder: URL) -> [String] {
        package.files.compactMap { entry in
            let relative = package.relativePath(of: entry.file, in: entry.source)
            let size =
                (try? FileManager.default.attributesOfItem(atPath: folder.appending(path: relative).path)[.size] as? Int)
                ?? nil
            return size == entry.file.size ? nil : relative
        }
    }

    private func partialBytes(_ package: ModelPackage) -> Int {
        let folder = partialFolder(package)
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey])
        else {
            return 0
        }
        var total = 0
        for case let url as URL in enumerator {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    // MARK: Download

    /// Downloads and verifies `package`, then moves it into place. Cancelling the task keeps the partial
    /// folder so the next call resumes. Returns the installed folder.
    @discardableResult
    public func install(
        _ package: ModelPackage, progress: @escaping @Sendable (ModelProgress) -> Void = { _ in }
    ) async throws -> URL {
        try await exclusive { try await performInstall(package, progress: progress) }
    }

    /// Runs `body` after every earlier install or delete has finished.
    private func exclusive<T>(_ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if exclusiveBusy {
            nextWaiterID += 1
            let id = nextWaiterID
            // A queued call that is cancelled leaves the queue at once and throws; it never holds the turn.
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    exclusiveWaiters.append((id, continuation))
                }
            } onCancel: {
                Task { await self.dropWaiter(id) }
            }
        } else {
            exclusiveBusy = true
        }
        defer {
            if exclusiveWaiters.isEmpty {
                exclusiveBusy = false
            } else {
                exclusiveWaiters.removeFirst().continuation.resume()
            }
        }
        try Task.checkCancellation()
        return try await body()
    }

    private func dropWaiter(_ id: Int) {
        guard let index = exclusiveWaiters.firstIndex(where: { $0.id == id }) else { return }
        exclusiveWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func performInstall(
        _ package: ModelPackage, progress: @escaping @Sendable (ModelProgress) -> Void
    ) async throws -> URL {
        let installed = installedFolder(package)
        if isComplete(package, in: installed) { return installed }

        let partial = partialFolder(package)
        try createPrivateDirectory(directory)
        try createPrivateDirectory(partial)

        // Space for what is still missing, plus 10%.
        let remaining = package.totalBytes - partialBytes(package)
        let needed = remaining + remaining / 10
        let available = availableSpace(directory)
        guard available >= needed else {
            throw ModelError.insufficientSpace(needed: needed, available: available)
        }

        let total = package.totalBytes
        let done = Counter(partialVerifiedBytes(package, in: partial))
        progress(ModelProgress(bytesDone: done.value, bytesTotal: total))

        for entry in package.files {
            try Task.checkCancellation()
            let relative = package.relativePath(of: entry.file, in: entry.source)
            let target = partial.appending(path: relative)
            try createPrivateDirectory(target.deletingLastPathComponent())
            // A finished file from an earlier attempt is already counted in `done` once verified.
            if fileSize(target) == entry.file.size {
                if try Self.sha256(of: target) == entry.file.sha256 { continue }
                // Same size, wrong content: start this file over.
                try FileManager.default.removeItem(at: target)
                done.add(-entry.file.size)
            }
            let part = target.appendingPathExtension("part")
            guard let url = entry.source.url(for: entry.file) else { throw ModelError.disallowedHost("") }
            let before = done.value
            try await downloader.download(url, to: part) { bytes in
                progress(ModelProgress(bytesDone: before + bytes, bytesTotal: total))
            }
            guard fileSize(part) == entry.file.size else {
                try? FileManager.default.removeItem(at: part)
                throw ModelError.sizeMismatch(path: relative)
            }
            guard try Self.sha256(of: part) == entry.file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                throw ModelError.checksumMismatch(path: relative)
            }
            try FileManager.default.moveItem(at: part, to: target)
            done.add(entry.file.size)
            progress(ModelProgress(bytesDone: done.value, bytesTotal: total))
        }

        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: partial, to: installed)
        logger.info("Installed speech model \(package.id, privacy: .public)")
        return installed
    }

    /// Bytes of files in the partial folder that are complete (their final names), for progress on resume.
    private func partialVerifiedBytes(_ package: ModelPackage, in partial: URL) -> Int {
        package.files.reduce(0) { sum, entry in
            let target = partial.appending(path: package.relativePath(of: entry.file, in: entry.source))
            return sum + (fileSize(target) == entry.file.size ? entry.file.size : 0)
        }
    }

    // MARK: User's own folder

    /// Checks a folder the user downloaded by hand: every file present with its size and SHA-256. Nothing is
    /// copied; the settings keep the folder's path.
    public func verify(folder: URL, for package: ModelPackage) throws {
        let missing = missingFiles(package, in: folder)
        guard missing.isEmpty else { throw ModelError.folderIncomplete(missing: missing) }
        for entry in package.files {
            let relative = package.relativePath(of: entry.file, in: entry.source)
            guard try Self.sha256(of: folder.appending(path: relative)) == entry.file.sha256 else {
                throw ModelError.checksumMismatch(path: relative)
            }
        }
    }

    // MARK: Delete

    /// Removes the downloaded package and any partial download. The user's own folder is never touched.
    public func delete(_ package: ModelPackage) async throws {
        try await exclusive {
            for url in [installedFolder(package), partialFolder(package)]
            where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Like `delete(_:)`, but asks `isInUse` once the turn is held and again right before the files go, with
    /// nothing in between that can suspend: a user that took the model after the caller's own check still
    /// stops the removal. Returns `false` (nothing removed) when the package is in use.
    @discardableResult
    public func delete(_ package: ModelPackage, unless isInUse: @Sendable () async -> Bool) async throws -> Bool {
        try await exclusive {
            if await isInUse() { return false }
            for url in [installedFolder(package), partialFolder(package)]
            where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        }
    }

    // MARK: Helpers

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// SHA-256 of a file, read in 1 MB pieces.
    public nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class Counter: @unchecked Sendable {
    private(set) var value: Int
    init(_ value: Int) { self.value = value }
    func add(_ amount: Int) { value += amount }
}
