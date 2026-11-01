import Foundation
import GRDB

/// A raw 256-bit SQLCipher key, handed to SQLCipher as a blob literal so no passphrase derivation
/// (PBKDF2) runs on top of the already random key. The bytes are never logged or described.
public struct DatabaseKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let byteCount = 32

    fileprivate let bytes: Data

    /// Returns `nil` unless exactly 32 bytes are given.
    public init?(rawBytes: Data) {
        guard rawBytes.count == Self.byteCount else { return nil }
        self.bytes = rawBytes
    }

    public var description: String { "DatabaseKey(redacted)" }
    public var debugDescription: String { description }

    /// `x'<64 hex digits>'`: SQLCipher's raw-key syntax.
    fileprivate var rawKeyLiteral: Data {
        let hex = bytes.map { byte in
            let digits = Array("0123456789abcdef".utf8)
            return [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        }
        return Data("x'".utf8) + Data(hex.joined()) + Data("'".utf8)
    }
}

/// Opens databases for one owner each (`ranking.sqlite` for the app, plugin databases for their
/// plugins), every one with its own `DatabaseMigrator`.
public enum DatabaseFactory {
    /// Opens or creates a database, encrypted with SQLCipher when a key is given, sets the file to
    /// mode 0600 and runs the owner's migrations.
    ///
    /// Opening an encrypted database without its key, or with a different key, throws
    /// (`SQLITE_NOTADB`) instead of returning unreadable data.
    public static func openQueue(
        at url: URL,
        key: DatabaseKey?,
        migrator: DatabaseMigrator,
        fileManager: FileManager = .default
    ) throws -> DatabaseQueue {
        var configuration = Configuration()
        if let key {
            configuration.prepareDatabase { db in
                try db.usePassphrase(key.rawKeyLiteral)
            }
        }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        // Reading the schema forces SQLCipher to decrypt the first page, so a wrong or missing key
        // fails here rather than on first use.
        _ = try queue.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try migrator.migrate(queue)
        return queue
    }

    /// The linked SQLCipher version (for example `4.20.0 community`), or `nil` when the library is
    /// plain SQLite. Proves at runtime which variant is linked.
    public static func sqlcipherVersion() throws -> String? {
        let queue = try DatabaseQueue()
        return try queue.read { db in try String.fetchOne(db, sql: "PRAGMA cipher_version") }
    }
}
