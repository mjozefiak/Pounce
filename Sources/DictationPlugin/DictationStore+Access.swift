import Foundation
import GRDB
import PouncePersistence

extension DictationStore {
    /// Opens (or creates) the encrypted database in `directory`.
    static func open(in directory: URL, keys: MasterKeys, fileManager: FileManager = .default) throws
        -> DictationStore
    {
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let queue = try DatabaseFactory.openQueue(
            at: directory.appending(path: fileName), key: keys.database, migrator: migrator, fileManager: fileManager)
        // Deleted rows are overwritten instead of lingering in free pages.
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        return DictationStore(database: queue)
    }

    var isClosed: Bool { closedFlag }

    func close() throws {
        try closeDatabase()
    }

    // MARK: Writing

    @discardableResult
    func insert(_ entry: DictationEntry) throws -> Int64 {
        try write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictation_entry (created_at, duration_ms, raw_text, formatted_text, format_mode,
                        format_status, detected_languages, speech_model_id, formatter_model, target_bundle_id,
                        paste_result)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.createdAt.timeIntervalSince1970, entry.durationMs, entry.rawText, entry.formattedText,
                    entry.formatMode.rawValue, entry.formatStatus.rawValue, entry.detectedLanguages,
                    entry.speechModelID, entry.formatterModel, entry.targetBundleID, entry.pasteResult.rawValue,
                ])
            return db.lastInsertedRowID
        }
    }

    func delete(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try write { db in
            for id in ids {
                try db.execute(sql: "DELETE FROM dictation_entry WHERE id = ?", arguments: [id])
            }
        }
    }

    func deleteAll() throws {
        try write { db in try db.execute(sql: "DELETE FROM dictation_entry") }
    }

    /// Deletes entries older than `cutoff` and everything beyond the `maximumCount` newest. Returns how many.
    @discardableResult
    func applyRetention(cutoff: Date, maximumCount: Int) throws -> Int {
        let ids = try read { db -> [Int64] in
            let old = try Int64.fetchAll(
                db, sql: "SELECT id FROM dictation_entry WHERE created_at < ?",
                arguments: [cutoff.timeIntervalSince1970])
            let surplus = try Int64.fetchAll(
                db, sql: "SELECT id FROM dictation_entry ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?",
                arguments: [max(0, maximumCount)])
            return Array(Set(old).union(surplus))
        }
        try delete(ids)
        return ids.count
    }

    func vacuum() throws {
        try access { try $0.vacuum() }
    }

    // MARK: Reading

    func count() throws -> Int {
        try read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM dictation_entry") ?? 0 }
    }

    /// Newest first, optionally only entries with (`formatted`) or without (`raw`) a cleaned text.
    func recent(limit: Int, filter: HistoryFilter? = nil) throws -> [DictationEntry] {
        try read { db in
            var sql = "SELECT * FROM dictation_entry"
            if let clause = filter?.clause { sql += " WHERE " + clause }
            sql += " ORDER BY created_at DESC, id DESC LIMIT ?"
            return try Row.fetchAll(db, sql: sql, arguments: [max(0, limit)]).compactMap(Self.entry)
        }
    }

    /// Full-text matches on the raw and the formatted text: every typed word as a prefix, best rank first.
    func search(_ text: String, limit: Int, filter: HistoryFilter? = nil) throws -> [DictationEntry] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try read { db in
            var sql = """
                SELECT dictation_entry.* FROM dictation_entry
                JOIN dictation_fts ON dictation_fts.rowid = dictation_entry.id
                WHERE dictation_fts MATCH ?
                """
            if let clause = filter?.clause { sql += " AND dictation_entry." + clause }
            sql += " ORDER BY dictation_fts.rank LIMIT ?"
            return try Row.fetchAll(db, sql: sql, arguments: [pattern, max(0, limit)]).compactMap(Self.entry)
        }
    }

    func entry(_ id: Int64) throws -> DictationEntry? {
        try read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM dictation_entry WHERE id = ?", arguments: [id])
                .flatMap(Self.entry)
        }
    }

    private static func entry(_ row: Row) -> DictationEntry? {
        guard let id: Int64 = row["id"], let created: Double = row["created_at"], let raw: String = row["raw_text"]
        else { return nil }
        return DictationEntry(
            id: id, createdAt: Date(timeIntervalSince1970: created), durationMs: row["duration_ms"] ?? 0,
            rawText: raw, formattedText: row["formatted_text"],
            formatMode: FormatMode(rawValue: row["format_mode"] ?? "") ?? .raw,
            formatStatus: FormatStatus(rawValue: row["format_status"] ?? "") ?? .none,
            detectedLanguages: row["detected_languages"] ?? "", speechModelID: row["speech_model_id"] ?? "",
            formatterModel: row["formatter_model"], targetBundleID: row["target_bundle_id"],
            pasteResult: PasteResult(rawValue: row["paste_result"] ?? "") ?? .pasted)
    }
}

/// The history list's filters (Command-1 to Command-3).
enum HistoryFilter: String, Sendable, CaseIterable {
    case all
    case formatted
    case raw

    /// The SQL condition, or `nil` for everything.
    var clause: String? {
        switch self {
        case .all: nil
        case .formatted: "formatted_text IS NOT NULL"
        case .raw: "formatted_text IS NULL"
        }
    }
}
