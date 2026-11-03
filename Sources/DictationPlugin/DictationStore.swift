import Foundation
import GRDB
import Synchronization

/// How the text was produced.
enum FormatMode: String, Sendable, CaseIterable {
    case raw
    case clean
}

/// What became of the formatting: `none` in raw mode, `ok` for every chunk, `partial` when some chunks stayed
/// raw, `failed` when all did.
enum FormatStatus: String, Sendable {
    case none
    case ok
    case partial
    case failed
}

enum PasteResult: String, Sendable {
    case pasted
    case copied
    case failed
}

/// One finished dictation (spec: Data Model → `dictation_entry`).
struct DictationEntry: Sendable, Equatable, Identifiable {
    var id: Int64 = 0
    var createdAt: Date
    var durationMs: Int
    /// The transcript before formatting.
    var rawText: String
    /// The cleaned text; `nil` in raw mode, or when formatting failed for every chunk.
    var formattedText: String?
    var formatMode: FormatMode
    var formatStatus: FormatStatus
    /// For example `pl,en`.
    var detectedLanguages: String
    var speechModelID: String
    var formatterModel: String?
    var targetBundleID: String?
    var pasteResult: PasteResult

    /// What Return pastes: the cleaned text when there is one.
    var bestText: String { formattedText ?? rawText }
}

enum DictationStoreError: Error {
    /// The store was closed (the plugin deactivated) while background work still used it.
    case closed
}

/// The encrypted dictation history: `dictation.sqlite` (SQLCipher) in `Plugins/dictation/`, with an FTS5 index
/// over the raw and the formatted text kept in sync by triggers (spec: Data Model). GRDB serialises access,
/// so the store is safe to use from any task. The text never reaches a log.
final class DictationStore: Sendable {
    static let fileName = "dictation.sqlite"

    private let database: DatabaseQueue
    private let lock = NSLock()
    private let closed = Mutex(false)

    init(database: DatabaseQueue) {
        self.database = database
    }

    var closedFlag: Bool { closed.withLock { $0 } }

    func read<T>(_ value: (Database) throws -> T) throws -> T {
        try access { try $0.read(value) }
    }

    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try access { try $0.write(updates) }
    }

    func closeDatabase() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closedFlag else { return }
        closed.withLock { $0 = true }
        try database.close()
    }

    func access<T>(_ body: (DatabaseQueue) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !closedFlag else { throw DictationStoreError.closed }
        return try body(database)
    }

    /// `dictation.sqlite`'s own migrator. Additive only, never edited once released
    /// (`BACKWARD_COMPATIBILITY.md` section 2).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-history") { db in
            try db.execute(
                sql: """
                    CREATE TABLE dictation_entry (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        created_at DOUBLE NOT NULL,
                        duration_ms INTEGER NOT NULL DEFAULT 0,
                        raw_text TEXT NOT NULL,
                        formatted_text TEXT,
                        format_mode TEXT NOT NULL DEFAULT 'raw',
                        format_status TEXT NOT NULL DEFAULT 'none',
                        detected_languages TEXT NOT NULL DEFAULT '',
                        speech_model_id TEXT NOT NULL DEFAULT '',
                        formatter_model TEXT,
                        target_bundle_id TEXT,
                        paste_result TEXT NOT NULL DEFAULT 'pasted'
                    );
                    CREATE INDEX dictation_entry_on_created_at ON dictation_entry(created_at);
                    """
            )
            try db.create(virtualTable: "dictation_fts", using: FTS5()) { table in
                table.synchronize(withTable: "dictation_entry")
                table.tokenizer = .unicode61()
                table.column("raw_text")
                table.column("formatted_text")
            }
        }
        return migrator
    }
}
