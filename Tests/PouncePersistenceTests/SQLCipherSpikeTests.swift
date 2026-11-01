import CryptoKit
import Foundation
import GRDB
import Testing

@testable import PouncePersistence

/// Spike 0.4: GRDB with SQLCipher through SwiftPM (docs/decisions/0001-sqlite.md).
/// A class, so `deinit` removes each test's temporary directory.
@Suite final class SQLCipherSpikeTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "pounce-persistence-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A sub-key derived the way the clipboard plugin will derive it: HKDF-SHA256 from a random
    /// master key with `info = "sqlcipher"`.
    static func derivedKey(from master: SymmetricKey) throws -> DatabaseKey {
        let subkey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            info: Data("sqlcipher".utf8),
            outputByteCount: DatabaseKey.byteCount
        )
        let bytes = subkey.withUnsafeBytes { Data($0) }
        return try #require(DatabaseKey(rawBytes: bytes))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: "CREATE TABLE note(id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
            try db.execute(sql: "CREATE VIRTUAL TABLE note_fts USING fts5(body)")
        }
        return migrator
    }

    @Test func linksSQLCipherRatherThanSystemSQLite() throws {
        let version = try #require(try DatabaseFactory.sqlcipherVersion())
        #expect(version.hasPrefix("4."))
    }

    @Test func encryptedDatabaseNeedsItsKey() throws {
        let url = directory.appending(path: "clipboard.sqlite")
        let key = try Self.derivedKey(from: SymmetricKey(size: .bits256))

        let queue = try DatabaseFactory.openQueue(at: url, key: key, migrator: Self.migrator)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO note(body) VALUES (?)", arguments: ["pounce-secret-marker"])
            try db.execute(sql: "INSERT INTO note_fts(body) VALUES (?)", arguments: ["pounce-secret-marker"])
        }
        try queue.close()

        // Without a key: SQLite error 26 (file is not a database).
        #expect(throws: DatabaseError.self) {
            _ = try DatabaseFactory.openQueue(at: url, key: nil, migrator: Self.migrator)
        }
        // With a different key: also refused.
        let otherKey = try Self.derivedKey(from: SymmetricKey(size: .bits256))
        #expect(throws: DatabaseError.self) {
            _ = try DatabaseFactory.openQueue(at: url, key: otherKey, migrator: Self.migrator)
        }
        // With the right key: data and the FTS5 index are readable.
        let reopened = try DatabaseFactory.openQueue(at: url, key: key, migrator: Self.migrator)
        let body = try reopened.read { db in try String.fetchOne(db, sql: "SELECT body FROM note") }
        #expect(body == "pounce-secret-marker")
        let hits = try reopened.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM note_fts WHERE note_fts MATCH 'secret'")
        }
        #expect(hits == 1)
        try reopened.close()
    }

    @Test func encryptedFileHasNoPlaintext() throws {
        let url = directory.appending(path: "clipboard.sqlite")
        let key = try Self.derivedKey(from: SymmetricKey(size: .bits256))
        let queue = try DatabaseFactory.openQueue(at: url, key: key, migrator: Self.migrator)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO note(body) VALUES (?)", arguments: ["pounce-secret-marker"])
        }
        try queue.close()

        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("SQLite format 3".utf8)) == nil)
        #expect(raw.range(of: Data("pounce-secret-marker".utf8)) == nil)
    }

    @Test func plainDatabaseStillWorks() throws {
        let url = directory.appending(path: "ranking.sqlite")
        let queue = try DatabaseFactory.openQueue(at: url, key: nil, migrator: Self.migrator)
        try queue.write { db in try db.execute(sql: "INSERT INTO note(body) VALUES ('x')") }
        try queue.close()

        let header = try Data(contentsOf: url).prefix(15)
        #expect(String(decoding: header, as: UTF8.self) == "SQLite format 3")
    }

    @Test func databaseFileIsPrivate() throws {
        let url = directory.appending(path: "ranking.sqlite")
        let queue = try DatabaseFactory.openQueue(at: url, key: nil, migrator: Self.migrator)
        try queue.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func keyRequiresThirtyTwoBytesAndIsRedacted() throws {
        #expect(DatabaseKey(rawBytes: Data(count: 31)) == nil)
        #expect(DatabaseKey(rawBytes: Data(count: 33)) == nil)
        let key = try #require(DatabaseKey(rawBytes: Data(repeating: 0xEF, count: 32)))
        #expect(String(describing: key) == "DatabaseKey(redacted)")
        #expect(!String(reflecting: key).lowercased().contains("efef"))
    }

    @Test func hkdfDerivationIsDeterministicAndDomainSeparated() throws {
        let master = SymmetricKey(size: .bits256)
        let first = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("sqlcipher".utf8), outputByteCount: 32)
        let again = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("sqlcipher".utf8), outputByteCount: 32)
        let blob = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data("blob".utf8), outputByteCount: 32)
        #expect(first == again)
        #expect(first != blob)
    }
}
