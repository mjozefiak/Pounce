import Foundation

/// The folders under `Plugins/meetings/Spool/`: one `<uuid>/` per meeting with `mic.spool`, `system.spool`
/// and a `.metadata_never_index` marker. The folder is 0700, the files 0600, and the folder is excluded from
/// Time Machine backups and (best effort) Spotlight. Also the `SpoolMaintenance` the retention job uses.
///
/// Spotlight limit: `.metadata_never_index` is honoured for the folder it sits in, but it is a convention of
/// `mds`, not a guarantee, and the folder cannot be renamed to `*.noindex` (the path is part of the format).
/// The content is encrypted anyway, so an indexed file reveals nothing; the marker only saves work.
struct SpoolStorage: SpoolMaintenance {
    static let neverIndexMarker = ".metadata_never_index"

    /// `.../Plugins/meetings/Spool`
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The spool root inside the plugin's data folder (`Plugins/meetings`).
    init(pluginDirectory: URL) {
        self.init(root: pluginDirectory.appending(path: "Spool", directoryHint: .isDirectory))
    }

    /// The folder and `info` name of a meeting: the lower-case canonical UUID.
    static func name(of meeting: UUID) -> String { meeting.uuidString.lowercased() }

    func directory(for meeting: UUID) -> URL {
        root.appending(path: Self.name(of: meeting), directoryHint: .isDirectory)
    }

    func file(for meeting: UUID, track: SpoolTrack) -> URL {
        directory(for: meeting).appending(path: "\(track.rawValue).spool", directoryHint: .notDirectory)
    }

    /// Creates the meeting's folder (idempotent) with the privacy attributes. An existing root or folder gets
    /// mode 0700 too; a symbolic link in place of either is refused.
    @discardableResult
    func prepare(meeting: UUID) throws -> URL {
        let fileManager = FileManager.default
        let directory = directory(for: meeting)
        try fileManager.createDirectory(
            at: root.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        for folder in [root, directory] {
            if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                throw SpoolError.ioFailure(errno: ELOOP)
            }
            try fileManager.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }

        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)

        let marker = directory.appending(path: Self.neverIndexMarker, directoryHint: .notDirectory)
        if !fileManager.fileExists(atPath: marker.path) {
            guard fileManager.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            else { throw SpoolError.ioFailure(errno: errno) }
        }
        return directory
    }

    /// Flushes a file to the disk: `F_FULLFSYNC` (asks the drive to empty its cache too), `fsync` where the
    /// file system does not support it.
    static func flush(_ descriptor: Int32) -> Bool {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return true }
        return fsync(descriptor) == 0
    }

    /// Makes a new directory entry durable: flushes the folder itself.
    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw SpoolError.ioFailure(errno: errno) }
        defer { Darwin.close(descriptor) }
        guard flush(descriptor) else { throw SpoolError.ioFailure(errno: errno) }
    }

    /// Free bytes on the volume of `url` (the nearest existing parent), for important usage.
    static func systemFreeSpace(at url: URL) throws -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: SpoolMaintenance

    /// Removes the folders of `uuids` (as given; a string that is not a UUID or a folder that is a symbolic
    /// link is skipped). Returns the uuids whose folder was removed.
    @discardableResult
    func removeSpools(forMeetings uuids: [String]) -> [String] {
        uuids.filter { uuid in
            guard let parsed = UUID(uuidString: uuid) else { return false }
            let directory = directory(for: parsed)
            guard isRealDirectory(directory) else { return false }
            return (try? FileManager.default.removeItem(at: directory)) != nil
        }
    }

    /// Only the folders of `candidates` are looked at, so a meeting being recorded or processed is out of reach
    /// whatever its age. Returns the candidates whose folder was last written before `cutoff` and was removed.
    @discardableResult
    func removeSpools(olderThan cutoff: Date, among candidates: Set<String>) -> [String] {
        candidates.sorted().filter { candidate in
            guard let parsed = UUID(uuidString: candidate) else { return false }
            let directory = directory(for: parsed)
            guard isRealDirectory(directory), let written = lastWrite(in: directory), written < cutoff else {
                return false
            }
            return (try? FileManager.default.removeItem(at: directory)) != nil
        }
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// The newest modification date of the folder and its files.
    private func lastWrite(in directory: URL) -> Date? {
        let fileManager = FileManager.default
        var newest = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let files =
            (try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? []
        for file in files {
            if let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                date > (newest ?? .distantPast)
            {
                newest = date
            }
        }
        return newest
    }
}
