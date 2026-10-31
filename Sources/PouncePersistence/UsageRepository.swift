import Foundation
import GRDB
import PounceKit

/// `ranking.sqlite`: usage statistics of rankable items, owned by `PounceApp` and shared with plugins
/// through the `UsageRecorder` port. Plain SQLite (no encryption): it holds bundle IDs, file paths and
/// short query prefixes, never anything from the clipboard.
///
/// Tables (spec: Data Model):
/// - `usage_stat(item_key PK, frecency, last_used_at, use_count)`; `frecency` is the score as of
///   `last_used_at` and decays with a seven-day half-life;
/// - `query_association(query_prefix, item_key, count, last_used_at)`, primary key
///   `(query_prefix, item_key)`, prefixes of 1–4 normalised characters.
///
/// Dates are stored as Unix seconds (`REAL`).
public final class UsageRepository: UsageRecorder {
    /// The file name at the Application Support root.
    public static let fileName = "ranking.sqlite"
    /// Query associations older than this are deleted when the repository opens.
    public static let associationRetention: TimeInterval = 90 * 24 * 60 * 60

    let queue: DatabaseQueue
    private let halfLife: TimeInterval

    /// - Parameter halfLife: frecency half-life; the `Ranker` decays with the same value.
    init(queue: DatabaseQueue, halfLife: TimeInterval) {
        self.queue = queue
        self.halfLife = halfLife
    }

    /// Opens or creates `ranking.sqlite` (mode 0600), migrates it and prunes stale associations.
    public static func open(
        at url: URL,
        halfLife: TimeInterval,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> UsageRepository {
        let queue = try DatabaseFactory.openQueue(at: url, key: nil, migrator: migrator, fileManager: fileManager)
        let repository = UsageRepository(queue: queue, halfLife: halfLife)
        try repository.pruneAssociations(olderThan: now.addingTimeInterval(-associationRetention))
        return repository
    }

    /// An in-memory database with the same schema, for tests.
    public static func inMemory(halfLife: TimeInterval) throws -> UsageRepository {
        let queue = try DatabaseQueue()
        try migrator.migrate(queue)
        return UsageRepository(queue: queue, halfLife: halfLife)
    }

    /// The ranking database's own migrator. Migrations are additive only and never edited once released
    /// (`BACKWARD_COMPATIBILITY.md` section 2).
    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-usage") { db in
            try db.create(table: "usage_stat") { table in
                table.column("item_key", .text).notNull().primaryKey()
                table.column("frecency", .double).notNull()
                table.column("last_used_at", .double).notNull()
                table.column("use_count", .integer).notNull()
            }
            try db.create(table: "query_association") { table in
                table.column("query_prefix", .text).notNull()
                table.column("item_key", .text).notNull()
                table.column("count", .integer).notNull()
                table.column("last_used_at", .double).notNull()
                table.primaryKey(["query_prefix", "item_key"])
            }
            try db.create(index: "query_association_last_used_at", on: "query_association", columns: ["last_used_at"])
        }
        return migrator
    }

    // MARK: UsageRecorder

    public func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {
        let halfLife = halfLife
        let prefixes = Self.prefixes(of: queryPrefix)
        try await queue.write { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT frecency, last_used_at FROM usage_stat WHERE item_key = ?",
                arguments: [key.rawValue]
            )
            let timestamp = date.timeIntervalSince1970
            var frecency = 1.0
            if let row {
                let previous: Double = row["frecency"]
                let lastUsed: Double = row["last_used_at"]
                frecency += previous * pow(2, -max(0, timestamp - lastUsed) / halfLife)
            }
            try db.execute(
                sql: """
                    INSERT INTO usage_stat (item_key, frecency, last_used_at, use_count) VALUES (?, ?, ?, 1)
                    ON CONFLICT(item_key) DO UPDATE SET
                        frecency = excluded.frecency,
                        last_used_at = excluded.last_used_at,
                        use_count = use_count + 1
                    """,
                arguments: [key.rawValue, frecency, timestamp]
            )
            for prefix in prefixes {
                try db.execute(
                    sql: """
                        INSERT INTO query_association (query_prefix, item_key, count, last_used_at) VALUES (?, ?, 1, ?)
                        ON CONFLICT(query_prefix, item_key) DO UPDATE SET
                            count = count + 1,
                            last_used_at = excluded.last_used_at
                        """,
                    arguments: [prefix, key.rawValue, timestamp]
                )
            }
        }
    }

    public func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] {
        guard !keys.isEmpty else { return [:] }
        let prefix = Self.prefixes(of: queryPrefix).last
        let rawKeys = keys.map(\.rawValue)
        return try await queue.read { db in
            var associations: [String: Int] = [:]
            if let prefix {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT item_key, count FROM query_association WHERE query_prefix = ?",
                    arguments: [prefix]
                )
                for row in rows {
                    associations[row["item_key"]] = row["count"]
                }
            }
            var result: [ItemKey: UsageStats] = [:]
            // SQLite limits bound parameters; app and file sections stay well below this chunk size.
            for chunk in stride(from: 0, to: rawKeys.count, by: 500) {
                let slice = Array(rawKeys[chunk..<min(chunk + 500, rawKeys.count)])
                let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT item_key, frecency, last_used_at, use_count FROM usage_stat
                        WHERE item_key IN (\(placeholders))
                        """,
                    arguments: StatementArguments(slice)
                )
                for row in rows {
                    let raw: String = row["item_key"]
                    guard let key = ItemKey(rawValue: raw) else { continue }
                    let lastUsed: Double = row["last_used_at"]
                    result[key] = UsageStats(
                        frecency: row["frecency"],
                        lastUsedAt: Date(timeIntervalSince1970: lastUsed),
                        useCount: row["use_count"],
                        queryAssociationCount: associations[raw] ?? 0
                    )
                }
            }
            return result
        }
    }

    public func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] {
        guard limit > 0 else { return [] }
        let halfLife = halfLife
        let (lower, upper) = Self.keyRange(of: pluginID)
        let timestamp = now.timeIntervalSince1970
        let scored: [(ItemKey, Double)] = try await queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT item_key, frecency, last_used_at FROM usage_stat
                    WHERE item_key >= ? AND item_key < ? AND use_count > 0
                    """,
                arguments: [lower, upper]
            )
            return rows.compactMap { row in
                let raw: String = row["item_key"]
                guard let key = ItemKey(rawValue: raw) else { return nil }
                let frecency: Double = row["frecency"]
                let lastUsed: Double = row["last_used_at"]
                return (key, frecency * pow(2, -max(0, timestamp - lastUsed) / halfLife))
            }
        }
        let sorted = scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
        return sorted.prefix(limit).map(\.0)
    }

    public func removeAll(pluginID: PluginID) async throws {
        let (lower, upper) = Self.keyRange(of: pluginID)
        try await queue.write { db in
            try db.execute(
                sql: "DELETE FROM usage_stat WHERE item_key >= ? AND item_key < ?",
                arguments: [lower, upper]
            )
            try db.execute(
                sql: "DELETE FROM query_association WHERE item_key >= ? AND item_key < ?",
                arguments: [lower, upper]
            )
        }
    }

    /// The half-open range of item keys that start with `<id>:`. `:` sorts right before `;`, so the range
    /// holds exactly one plugin's keys and lookups use the primary key index.
    static func keyRange(of pluginID: PluginID) -> (lower: String, upper: String) {
        (pluginID.rawValue + ":", pluginID.rawValue + ";")
    }

    // MARK: Maintenance

    /// Deletes query associations last used before `date`.
    public func pruneAssociations(olderThan date: Date) throws {
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM query_association WHERE last_used_at < ?",
                arguments: [date.timeIntervalSince1970]
            )
        }
    }

    /// Prefixes of 1 to 4 characters of a normalised query, shortest first.
    static func prefixes(of query: String?) -> [String] {
        guard let query, !query.isEmpty else { return [] }
        let characters = Array(query.prefix(4))
        return (1...characters.count).map { String(characters[0..<$0]) }
    }
}
