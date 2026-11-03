import Foundation

/// The folders under `Plugins/meetings/Spool/`: one `<uuid>/` per meeting with `mic.spool`, `system.spool`
/// and a `.metadata_never_index` marker. The folder is 0700, the files 0600, and the folder is excluded from
/// Time Machine backups and Spotlight. Also the `SpoolMaintenance` the retention job uses.
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

    /// Creates the meeting's folder (idempotent) with the privacy attributes.
    @discardableResult
    func prepare(meeting: UUID) throws -> URL {
        let fileManager = FileManager.default
        let directory = directory(for: meeting)
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

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

    @discardableResult
    func removeSpools(forMeetings uuids: [String]) -> Int {
        var removed = 0
        for uuid in uuids {
            guard let parsed = UUID(uuidString: uuid) else { continue }
            let directory = directory(for: parsed)
            guard isRealDirectory(directory) else { continue }
            if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
        }
        return removed
    }

    @discardableResult
    func removeSpools(olderThan cutoff: Date) -> Int {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [])
        else { return 0 }
        var removed = 0
        for directory in entries where UUID(uuidString: directory.lastPathComponent) != nil {
            guard isRealDirectory(directory), let written = lastWrite(in: directory), written < cutoff else { continue }
            if (try? fileManager.removeItem(at: directory)) != nil { removed += 1 }
        }
        return removed
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
