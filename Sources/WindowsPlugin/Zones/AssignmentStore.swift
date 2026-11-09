import Foundation
import LintelPersistence
import os

/// The JSON shape of `assignments.json` (spec: Data Model). Version 1:
/// `{"version":1,"assignments":[{"workspace":1,"displayKey":"…","layoutID":"stock.columns2"}]}`.
struct AssignmentFile: Codable, Equatable {
    static let currentVersion = 1

    struct Entry: Codable, Equatable {
        var workspace: Int
        var displayKey: String
        var layoutID: String
    }

    var version: Int
    var assignments: [Entry]

    init(version: Int = Self.currentVersion, table: AssignmentTable) {
        self.version = version
        assignments = table.entries.sorted {
            ($0.workspace, $0.displayKey) < ($1.workspace, $1.displayKey)
        }.map { Entry(workspace: $0.workspace.rawValue, displayKey: $0.displayKey, layoutID: $0.layoutID) }
    }

    /// The table this file describes; entries for workspaces outside 1 through 9, with an empty key or id, and a
    /// second entry for the same cell are dropped. A stock id is always valid; any other id is checked when the
    /// layout is resolved, so an unknown one falls back and is reported instead of being lost.
    var table: AssignmentTable {
        var seen = Set<String>()
        var entries: [ZoneAssignment] = []
        for entry in assignments {
            guard let workspace = WorkspaceID(entry.workspace), !entry.displayKey.isEmpty, !entry.layoutID.isEmpty,
                seen.insert("\(entry.workspace)|\(entry.displayKey)").inserted
            else { continue }
            entries.append(ZoneAssignment(workspace: workspace, displayKey: entry.displayKey, layoutID: entry.layoutID))
        }
        return AssignmentTable(entries)
    }
}

/// Owner of `Plugins/windows/assignments.json`: which layout each workspace uses on each display. Separate from
/// the layout library so a damaged assignment file can never archive the user's layouts. Small and written only
/// on a user action, so every change is written at once (`AtomicFile`). A file that does not decode is moved to
/// one `assignments.json.corrupt` copy and the table starts empty; a file from a newer version is read as well as
/// it can be and never written; a file that cannot be read blocks writes for the session. Errors are logged
/// without display keys.
actor AssignmentStore {
    static let fileName = "assignments.json"
    static let corruptFileName = "assignments.json.corrupt"

    enum StoreError: Error, Equatable {
        case readOnly
        case write
    }

    /// One step of the version migration seam: turns the JSON of version N into the JSON of version N + 1.
    typealias Migration = @Sendable (Data) -> Data?

    nonisolated let fileURL: URL
    nonisolated var corruptURL: URL { fileURL.deletingLastPathComponent().appending(path: Self.corruptFileName) }
    private let logger: Logger
    private let currentVersion: Int
    private let migrations: [Int: Migration]
    private(set) var table = AssignmentTable()
    private(set) var isReadOnly = false

    init(
        directory: URL, currentVersion: Int = AssignmentFile.currentVersion, migrations: [Int: Migration] = [:],
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "windows")
    ) {
        fileURL = directory.appending(path: Self.fileName)
        self.currentVersion = currentVersion
        self.migrations = migrations
        self.logger = logger
    }

    // MARK: Loading

    func load() {
        isReadOnly = false
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            table = AssignmentTable()
            if (error as NSError).code != NSFileReadNoSuchFileError {
                logger.error("Cannot read assignments.json")
                isReadOnly = true
            }
            return
        }
        struct Header: Decodable { var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.version >= 1 else {
            logger.error("assignments.json is corrupt; starting without assignments")
            setAsideCorruptFile()
            table = AssignmentTable()
            return
        }
        if header.version > currentVersion {
            logger.notice("assignments.json comes from a newer version; it is read-only")
            table = (try? JSONDecoder().decode(AssignmentFile.self, from: data))?.table ?? AssignmentTable()
            isReadOnly = true
            return
        }
        var current = data
        var version = header.version
        while version < currentVersion {
            guard let step = migrations[version], let next = step(current) else {
                logger.error("assignments.json cannot be migrated")
                setAsideCorruptFile()
                table = AssignmentTable()
                return
            }
            current = next
            version += 1
        }
        guard let file = try? JSONDecoder().decode(AssignmentFile.self, from: current) else {
            logger.error("assignments.json is corrupt; starting without assignments")
            setAsideCorruptFile()
            table = AssignmentTable()
            return
        }
        table = file.table
    }

    private func setAsideCorruptFile() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: corruptURL)
        do {
            try fileManager.moveItem(at: fileURL, to: corruptURL)
        } catch {
            logger.error("Cannot set aside assignments.json")
            isReadOnly = true
        }
    }

    // MARK: Changing

    /// Sets (or, with `nil`, clears) the layout of one cell and writes the file.
    func set(_ layoutID: String?, workspace: WorkspaceID, displayKey: String) throws {
        var next = table
        next.set(layoutID, workspace: workspace, displayKey: displayKey)
        try write(next)
    }

    /// Replaces many cells in one write (*Apply to…*): a `nil` layout clears the cell.
    func setAll(_ changes: [(workspace: WorkspaceID, displayKey: String, layoutID: String?)]) throws {
        var next = table
        for change in changes { next.set(change.layoutID, workspace: change.workspace, displayKey: change.displayKey) }
        try write(next)
    }

    /// Forgets every assignment (*Reset state* clears assignments only through here, so it is a user action).
    func reset() throws { try write(AssignmentTable()) }

    private func write(_ next: AssignmentTable) throws {
        guard !isReadOnly else { throw StoreError.readOnly }
        guard next != table else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(AssignmentFile(version: currentVersion, table: next))
            try AtomicFile.write(data, to: fileURL)
        } catch {
            logger.error("Cannot write assignments.json")
            throw StoreError.write
        }
        table = next
    }
}
