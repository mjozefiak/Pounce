import CryptoKit
import Foundation
import GRDB
import PounceKit
import PouncePersistence

/// The encrypted clipboard history: `clipboard.sqlite` (SQLCipher) plus AES-GCM blob files in
/// `blobs/`, both in `Plugins/clipboard/` (spec: Data Model).
///
/// - `clip_item`: one row per entry, deduplicated by `content_hash`, an HMAC-SHA256 of the sorted
///   representations under the `content-hash` sub-key (never a bare SHA-256 of clipboard content).
/// - `clip_representation`: the entry's representations. Up to `inlineLimit` bytes the data is a
///   column; above it the data goes to `blobs/<random UUID>`, sealed with AES-GCM under the `blob`
///   sub-key, with the file name as authenticated data.
/// - `clip_fts`: FTS5 over `clip_item.preview_text`, kept in sync by triggers.
///
/// Deleting an entry (by hand, by retention or by "Clear History") deletes its blob files too, and
/// `sweepOrphans()` removes any file no row points at. GRDB's `DatabaseQueue` serialises access, so the
/// store is safe to use from any task.
final class ClipStore: Sendable {
    static let fileName = "clipboard.sqlite"
    static let blobsDirectoryName = "blobs"
    /// Representations above 1 MB go to blob files.
    static let inlineLimit = 1 << 20
    /// The longest preview text stored for search and shown in the preview pane.
    static let maximumPreviewLength = 10_000
    /// List rows carry only the start of the preview text.
    static let summaryPreviewLength = 300

    let queue: DatabaseQueue
    let blobsDirectory: URL
    private let keys: ClipKeys

    init(queue: DatabaseQueue, keys: ClipKeys, blobsDirectory: URL) {
        self.queue = queue
        self.keys = keys
        self.blobsDirectory = blobsDirectory
    }

    /// Opens (or creates) the encrypted database in `directory` and its `blobs/` folder.
    static func open(in directory: URL, keys: ClipKeys, fileManager: FileManager = .default) throws -> ClipStore {
        let blobs = directory.appending(path: blobsDirectoryName, directoryHint: .isDirectory)
        try createPrivateDirectory(blobs, fileManager: fileManager)
        let queue = try DatabaseFactory.openQueue(
            at: directory.appending(path: fileName),
            key: keys.database,
            migrator: migrator,
            fileManager: fileManager
        )
        // Deleted rows are overwritten instead of lingering in free pages.
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA secure_delete = ON") }
        return ClipStore(queue: queue, keys: keys, blobsDirectory: blobs)
    }

    /// `clipboard.sqlite`'s own migrator. Migrations are additive only and never edited once released
    /// (`BACKWARD_COMPATIBILITY.md` section 2).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-clipboard") { db in
            try db.execute(
                sql: """
                    CREATE TABLE clip_item (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        content_hash BLOB NOT NULL UNIQUE,
                        kind TEXT NOT NULL,
                        preview_text TEXT NOT NULL DEFAULT '',
                        source_bundle_id TEXT,
                        source_app_name TEXT,
                        created_at DOUBLE NOT NULL,
                        last_used_at DOUBLE NOT NULL,
                        use_count INTEGER NOT NULL DEFAULT 0,
                        byte_size INTEGER NOT NULL DEFAULT 0
                    );
                    CREATE INDEX clip_item_on_last_used_at ON clip_item(last_used_at);
                    CREATE TABLE clip_representation (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        item_id INTEGER NOT NULL REFERENCES clip_item(id) ON DELETE CASCADE,
                        item_index INTEGER NOT NULL DEFAULT 0,
                        uti TEXT NOT NULL,
                        data BLOB,
                        blob_file TEXT,
                        byte_size INTEGER NOT NULL
                    );
                    CREATE INDEX clip_representation_on_item_id ON clip_representation(item_id);
                    """
            )
            try db.create(virtualTable: "clip_fts", using: FTS5()) { table in
                table.synchronize(withTable: "clip_item")
                table.tokenizer = .unicode61()
                table.column("preview_text")
            }
        }
        return migrator
    }

    func close() throws {
        try queue.close()
    }

    // MARK: Writing

    enum InsertOutcome: Equatable, Sendable {
        case inserted(Int64)
        /// An entry with the same content existed; it moved to the top instead of a new row.
        case duplicate(Int64)
    }

    /// Stores a captured entry, or moves an identical existing one to the top.
    @discardableResult
    func insert(_ draft: ClipDraft) throws -> InsertOutcome {
        let hash = contentHash(draft.items)
        let time = draft.capturedAt.timeIntervalSince1970
        if let existing = try queue.write({ db -> Int64? in
            guard
                let id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM clip_item WHERE content_hash = ?", arguments: [hash])
            else { return nil }
            try db.execute(
                sql: "UPDATE clip_item SET last_used_at = MAX(last_used_at, ?) WHERE id = ?",
                arguments: [time, id]
            )
            return id
        }) {
            return .duplicate(existing)
        }

        // Blob files are written before the rows that point at them; if the insert fails they are
        // removed again, and the orphan sweep catches anything a crash leaves behind.
        var written: [URL] = []
        var rows: [(itemIndex: Int, type: String, data: Data?, blobFile: String?, size: Int)] = []
        do {
            for (index, item) in draft.items.enumerated() {
                for representation in item.representations {
                    if representation.data.count > Self.inlineLimit {
                        let name = UUID().uuidString
                        let url = try writeBlob(representation.data, name: name)
                        written.append(url)
                        rows.append((index, representation.type, nil, name, representation.data.count))
                    } else {
                        rows.append((index, representation.type, representation.data, nil, representation.data.count))
                    }
                }
            }
            let preview = String(draft.previewText.prefix(Self.maximumPreviewLength))
            let outcome = try queue.write { db -> InsertOutcome in
                // Another capture may have stored the same content meanwhile.
                if let id = try Int64.fetchOne(
                    db, sql: "SELECT id FROM clip_item WHERE content_hash = ?", arguments: [hash])
                {
                    return .duplicate(id)
                }
                try db.execute(
                    sql: """
                        INSERT INTO clip_item (content_hash, kind, preview_text, source_bundle_id, source_app_name,
                            created_at, last_used_at, use_count, byte_size)
                        VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)
                        """,
                    arguments: [
                        hash, draft.kind.rawValue, preview, draft.sourceBundleID, draft.sourceAppName, time, time,
                        draft.byteSize,
                    ]
                )
                let id = db.lastInsertedRowID
                for row in rows {
                    try db.execute(
                        sql: """
                            INSERT INTO clip_representation (item_id, item_index, uti, data, blob_file, byte_size)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [id, row.itemIndex, row.type, row.data, row.blobFile, row.size]
                    )
                }
                return .inserted(id)
            }
            if case .duplicate = outcome {
                removeFiles(written)
            }
            return outcome
        } catch {
            removeFiles(written)
            throw error
        }
    }

    /// Records a paste or copy from the history: the frecency signal (`use_count`, `last_used_at`).
    func markUsed(_ id: Int64, at date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "UPDATE clip_item SET use_count = use_count + 1, last_used_at = ? WHERE id = ?",
                arguments: [date.timeIntervalSince1970, id]
            )
        }
    }

    /// Deletes entries and their blob files.
    func delete(_ ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        let files = try queue.write { db -> [String] in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let arguments = StatementArguments(ids)
            let files = try String.fetchAll(
                db,
                sql:
                    "SELECT blob_file FROM clip_representation WHERE blob_file IS NOT NULL AND item_id IN (\(placeholders))",
                arguments: arguments
            )
            try db.execute(sql: "DELETE FROM clip_item WHERE id IN (\(placeholders))", arguments: arguments)
            return files
        }
        removeFiles(files.map(blobURL))
    }

    /// "Clear History": an empty database and an empty `blobs/` folder.
    func deleteAll() throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM clip_item")
            try db.execute(sql: "INSERT INTO clip_fts(clip_fts) VALUES ('rebuild')")
        }
        try queue.vacuum()
        let files =
            (try? FileManager.default.contentsOfDirectory(at: blobsDirectory, includingPropertiesForKeys: nil)) ?? []
        removeFiles(files)
    }

    /// Deletes entries last used before `cutoff` and everything beyond the `maximumCount` most recently
    /// used. Returns how many entries were deleted.
    @discardableResult
    func applyRetention(cutoff: Date, maximumCount: Int) throws -> Int {
        let ids = try queue.read { db -> [Int64] in
            let old = try Int64.fetchAll(
                db, sql: "SELECT id FROM clip_item WHERE last_used_at < ?", arguments: [cutoff.timeIntervalSince1970])
            let surplus = try Int64.fetchAll(
                db,
                sql: "SELECT id FROM clip_item ORDER BY last_used_at DESC, id DESC LIMIT -1 OFFSET ?",
                arguments: [max(0, maximumCount)]
            )
            return Array(Set(old).union(surplus))
        }
        try delete(ids)
        return ids.count
    }

    /// Removes blob files no row points at (a crash between writing a file and its row, or an
    /// interrupted delete). Returns how many files were removed.
    @discardableResult
    func sweepOrphans() throws -> Int {
        let referenced = Set(
            try queue.read { db in
                try String.fetchAll(db, sql: "SELECT blob_file FROM clip_representation WHERE blob_file IS NOT NULL")
            })
        let files =
            (try? FileManager.default.contentsOfDirectory(at: blobsDirectory, includingPropertiesForKeys: nil)) ?? []
        let orphans = files.filter { !referenced.contains($0.lastPathComponent) }
        removeFiles(orphans)
        return orphans.count
    }

    // MARK: Reading

    func count() throws -> Int {
        try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM clip_item") ?? 0 }
    }

    /// The most recently used entries, optionally of one kind.
    func recent(limit: Int, kind: ClipKind? = nil) throws -> [ClipSummary] {
        try queue.read { db in
            var sql = "SELECT \(Self.summaryColumns) FROM clip_item"
            var arguments: StatementArguments = []
            if let kind {
                sql += " WHERE kind = ?"
                arguments += [kind.rawValue]
            }
            sql += " ORDER BY last_used_at DESC, id DESC LIMIT ?"
            arguments += [max(0, limit)]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.summary)
        }
    }

    /// Full-text matches: every typed word as a prefix (`FTS5Pattern(matchingAllPrefixesIn:)`), best
    /// FTS rank first.
    func search(_ text: String, limit: Int, kind: ClipKind? = nil) throws -> [ClipSummary] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }
        return try queue.read { db in
            var sql = """
                SELECT \(Self.summaryColumns("clip_item")) FROM clip_item
                JOIN clip_fts ON clip_fts.rowid = clip_item.id
                WHERE clip_fts MATCH ?
                """
            var arguments: StatementArguments = [pattern]
            if let kind {
                sql += " AND clip_item.kind = ?"
                arguments += [kind.rawValue]
            }
            sql += " ORDER BY clip_fts.rank LIMIT ?"
            arguments += [max(0, limit)]
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.summary)
        }
    }

    /// An entry with its decrypted representations, or `nil` when it no longer exists.
    func detail(_ id: Int64) throws -> ClipDetail? {
        let loaded = try queue.read { db -> (ClipSummary, String, [Row])? in
            guard
                let row = try Row.fetchOne(
                    db, sql: "SELECT \(Self.summaryColumns), preview_text AS full_text FROM clip_item WHERE id = ?",
                    arguments: [id]),
                let summary = Self.summary(row)
            else { return nil }
            let representations = try Row.fetchAll(
                db,
                sql: "SELECT item_index, uti, data, blob_file FROM clip_representation WHERE item_id = ? ORDER BY id",
                arguments: [id]
            )
            return (summary, row["full_text"] ?? "", representations)
        }
        guard let (summary, fullText, rows) = loaded else { return nil }
        var grouped: [Int: [PasteboardRepresentation]] = [:]
        for row in rows {
            let index: Int = row["item_index"] ?? 0
            let type: String = row["uti"] ?? ""
            let data: Data
            if let inline: Data = row["data"] {
                data = inline
            } else if let file: String = row["blob_file"] {
                data = try readBlob(name: file)
            } else {
                continue
            }
            grouped[index, default: []].append(PasteboardRepresentation(type: type, data: data))
        }
        let items = grouped.keys.sorted().compactMap { index in
            grouped[index].map { PasteboardItem(representations: $0) }
        }
        return ClipDetail(summary: summary, previewText: fullText, items: items)
    }

    // MARK: Hashing and blobs

    /// HMAC-SHA256 under the `content-hash` sub-key over every representation, sorted by item and type,
    /// each framed with its index, type and length so different splits never collide.
    func contentHash(_ items: [PasteboardItem]) -> Data {
        var hmac = HMAC<SHA256>(key: keys.contentHash)
        for (index, item) in items.enumerated() {
            for representation in item.representations.sorted(by: { $0.type < $1.type }) {
                hmac.update(
                    data: Data("\(index)\u{0}\(representation.type)\u{0}\(representation.data.count)\u{0}".utf8))
                hmac.update(data: representation.data)
            }
        }
        return Data(hmac.finalize())
    }

    func blobURL(_ name: String) -> URL {
        blobsDirectory.appending(path: name)
    }

    private func writeBlob(_ data: Data, name: String) throws -> URL {
        let sealed = try AES.GCM.seal(data, using: keys.blob, authenticating: Data(name.utf8))
        guard let combined = sealed.combined else { throw ClipStoreError.cannotEncrypt }
        let url = blobURL(name)
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: combined, attributes: [.posixPermissions: 0o600])
        else { throw ClipStoreError.cannotWriteBlob }
        return url
    }

    private func readBlob(name: String) throws -> Data {
        let combined = try Data(contentsOf: blobURL(name))
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: keys.blob, authenticating: Data(name.utf8))
    }

    private func removeFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Rows

    private static let summaryColumns = summaryColumns(nil)

    private static func summaryColumns(_ table: String?) -> String {
        let prefix = table.map { "\($0)." } ?? ""
        return """
            \(prefix)id AS id, \(prefix)kind AS kind, substr(\(prefix)preview_text, 1, \(summaryPreviewLength)) AS preview,
            \(prefix)source_bundle_id AS source_bundle_id, \(prefix)source_app_name AS source_app_name,
            \(prefix)created_at AS created_at, \(prefix)last_used_at AS last_used_at,
            \(prefix)use_count AS use_count, \(prefix)byte_size AS byte_size
            """
    }

    private static func summary(_ row: Row) -> ClipSummary? {
        guard let id: Int64 = row["id"], let kindValue: String = row["kind"], let kind = ClipKind(rawValue: kindValue)
        else { return nil }
        return ClipSummary(
            id: id,
            kind: kind,
            previewText: row["preview"] ?? "",
            sourceBundleID: row["source_bundle_id"],
            sourceAppName: row["source_app_name"],
            createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0),
            lastUsedAt: Date(timeIntervalSince1970: row["last_used_at"] ?? 0),
            useCount: row["use_count"] ?? 0,
            byteSize: row["byte_size"] ?? 0
        )
    }

    static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

enum ClipStoreError: Error, Sendable {
    case cannotEncrypt
    case cannotWriteBlob
}
