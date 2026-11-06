import Foundation
import GRDB
import LintelPersistence
import Synchronization

/// `note_revision.state`.
enum NoteRevisionState: String, Sendable, CaseIterable {
    case applied
    case proposed
    case discarded
}

/// `note_doc.source_state` (`nil` for manual notes).
enum NoteSourceState: String, Sendable {
    case present
    case detached
}

/// The encrypted notes store: `notes.sqlite` (SQLCipher) in `Plugins/notes/` with one FTS5 index over the
/// title and the head body of applied revisions (spec "Data Model"). GRDB serialises access, so the store is
/// safe to use from any task. Titles, bodies and comments never reach a log.
///
/// Every write goes through `write`, which refuses while the store is read-only: a database from a newer
/// Lintel (`schemaNewer`), or the hidden `plugins.notes.readOnly` setting (`readOnly`). Reads always work.
final class NotesStore: Sendable {
    static let fileName = "notes.sqlite"

    private let database: DatabaseQueue
    private let closed = Mutex(false)
    /// Why writes are refused right now, or `nil`. Read on every write, so the setting applies at once.
    private let writeBlock: @Sendable () -> NotesError?
    /// The database was written by a newer Lintel (a migration this build does not know is applied).
    let hasNewerSchema: Bool

    init(
        database: DatabaseQueue, hasNewerSchema: Bool = false,
        writeBlock: @escaping @Sendable () -> NotesError? = { nil }
    ) {
        self.database = database
        self.hasNewerSchema = hasNewerSchema
        self.writeBlock = writeBlock
    }

    var isClosed: Bool { closed.withLock { $0 } }

    /// Why a write would be refused now.
    var blockedReason: NotesError? { hasNewerSchema ? .schemaNewer : writeBlock() }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try access { try $0.read(value) }
    }

    /// One write transaction. Throws `schemaNewer` or `readOnly` without touching the database.
    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        if let reason = blockedReason { throw reason }
        return try access { try $0.write(updates) }
    }

    func vacuum() throws {
        if let reason = blockedReason { throw reason }
        try access { try $0.vacuum() }
    }

    func close() throws {
        let already = closed.withLock { flag -> Bool in
            let was = flag
            flag = true
            return was
        }
        guard !already else { return }
        try database.close()
    }

    private func access<T>(_ body: (DatabaseQueue) throws -> T) throws -> T {
        guard !isClosed else { throw NotesError.storeClosed }
        do {
            return try body(database)
        } catch {
            if isClosed, error is DatabaseError { throw NotesError.storeClosed }
            throw error
        }
    }

    /// Opens (or creates) the encrypted database in `directory` (mode 0700; the file is 0600).
    static func open(
        in directory: URL, keys: NotesKeys, fileManager: FileManager = .default,
        writeBlock: @escaping @Sendable () -> NotesError? = { nil }
    ) throws -> NotesStore {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let queue = try DatabaseFactory.openQueue(
            at: directory.appending(path: fileName), key: keys.database, migrator: migrator, fileManager: fileManager)
        do {
            // Deleted rows are overwritten instead of lingering in free pages.
            try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
            let applied = try queue.read { db in try migrator.appliedIdentifiers(db) }
            let known = Set(migrator.migrations)
            let newer = !applied.isSubset(of: known)
            return NotesStore(database: queue, hasNewerSchema: newer, writeBlock: writeBlock)
        } catch {
            try? queue.close()
            throw error
        }
    }
}
