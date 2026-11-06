import Foundation
import GRDB
import LintelKit
import LintelPersistence
import Testing

@testable import NotesPlugin

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesKeyTests {
    @Test func theKeyUsesTheDocumentedServiceAndIsRedacted() throws {
        #expect(NotesKeyStore.service == "com.lintelapp.notes")
        let keys = try #require(MasterKeys(master: Data(repeating: 7, count: 32)))
        let notes = NotesKeys(keys)
        #expect(notes.description == "NotesKeys(redacted)")
        #expect("\(notes)" == "NotesKeys(redacted)")
        #expect(NotesKeyStore(keychain: MemoryKeychain()).master.legacyService == nil)
    }

    @Test func aKeyThatDoesNotExistIsMissingAndOtherErrorsAreFailures() {
        let keychain = MemoryKeychain()
        guard case .missing = NotesKeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .missing")
            return
        }
        keychain.failReads(with: .interactionNotAllowed)
        guard case .failed(.locked) = NotesKeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .failed(.locked), never .missing")
            return
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct NotesOpenerTests {
    @Test func openingCreatesTheKeyAndAPrivateEncryptedLibrary() throws {
        let harness = try NotesHarness()
        let opener = harness.opener()
        #expect(opener.status == .closed)
        #expect(!opener.canEdit)
        opener.open()
        #expect(opener.status == .ready)
        #expect(opener.canEdit)
        #expect(opener.resetArchive == nil)
        #expect(harness.keychain.itemNames == ["com.lintelapp.notes/master-key"])
        #expect(try fileMode(harness.directory) == 0o700)
        let file = harness.directory.appending(path: "notes.sqlite")
        #expect(try fileMode(file) == 0o600)
        let header = try Data(contentsOf: file).prefix(15)
        #expect(String(decoding: header, as: UTF8.self) != "SQLite format 3")
        opener.close()
        #expect(opener.status == .closed)
        #expect(opener.store == nil)
    }

    @Test func openingTwiceDoesNotReadTheKeychainAgain() throws {
        let harness = try NotesHarness()
        let opener = harness.opener()
        opener.open()
        let reads = harness.keychain.readCount
        opener.open()
        #expect(harness.keychain.readCount == reads)
    }

    @Test func aLockedOrDeniedKeychainDisablesEditingAndDeletesNothing() throws {
        let harness = try NotesHarness()
        let first = harness.opener()
        first.open()
        let store = try #require(first.store)
        try store.insertDocument(.manual("a"))
        first.close()
        let file = harness.directory.appending(path: "notes.sqlite")
        let before = try Data(contentsOf: file)

        for failure in [KeychainError.interactionNotAllowed, .accessDenied, .unexpected(status: -1)] {
            harness.keychain.failReads(with: failure)
            let opener = harness.opener()
            opener.open()
            guard case .unavailable = opener.status else {
                Issue.record("expected .unavailable for \(failure)")
                continue
            }
            #expect(opener.store == nil)
            #expect(!opener.canEdit)
            #expect(!opener.canRead)
            #expect(opener.resetArchive == nil)
        }
        #expect(try Data(contentsOf: file) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: harness.directory.path)
        #expect(names.allSatisfy { !$0.contains(".unreadable-") })
        #expect(harness.keychain.deleteCount == 0)
    }

    @Test func aLockedKeychainBeforeAnyDatabaseCreatesNoFile() throws {
        let harness = try NotesHarness()
        harness.keychain.failReads(with: .accessDenied)
        let opener = harness.opener()
        opener.open()
        #expect(opener.status == .unavailable(.denied))
        #expect(!FileManager.default.fileExists(atPath: harness.directory.path))
        #expect(harness.keychain.itemNames.isEmpty)
    }

    @Test func aMalformedKeyIsReportedNotReplaced() throws {
        let harness = try NotesHarness()
        try harness.keychain.addGenericPassword(
            Data(repeating: 1, count: 5), service: "com.lintelapp.notes", account: "master-key")
        let opener = harness.opener()
        opener.open()
        #expect(opener.status == .unavailable(.malformedKey))
        #expect(harness.keychain.itemNames == ["com.lintelapp.notes/master-key"])
        #expect(!FileManager.default.fileExists(atPath: harness.directory.path))
    }

    @Test func onlyAMissingKeyArchivesTheOldDatabaseAndStartsANewOne() throws {
        let harness = try NotesHarness()
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let first = harness.opener(now: { stamp })
        first.open()
        try #require(first.store).insertDocument(.manual("old"))
        first.close()
        try harness.keychain.deleteGenericPassword(service: "com.lintelapp.notes", account: "master-key")

        let second = harness.opener(now: { stamp })
        second.open()
        #expect(second.status == .ready)
        let archive = try #require(second.resetArchive)
        #expect(archive.lastPathComponent == "notes.sqlite.unreadable-\(EncryptedDatabaseOpener.stamp(stamp))")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try #require(second.store).manualOverlays().isEmpty)
        #expect(harness.keychain.itemNames == ["com.lintelapp.notes/master-key"])
    }

    @Test func archivesOlderThanThirtyDaysArePurgedOnOpen() throws {
        let harness = try NotesHarness()
        try FileManager.default.createDirectory(at: harness.directory, withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        let name = "notes.sqlite.unreadable-\(EncryptedDatabaseOpener.stamp(old))"
        let archive = harness.directory.appending(path: name)
        try Data("x".utf8).write(to: archive)
        let opener = harness.opener(now: { old.addingTimeInterval(31 * 86_400) })
        opener.open()
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test func aDatabaseFromANewerLintelIsReadableAndNeverWritten() throws {
        let harness = try NotesHarness()
        let first = harness.opener()
        first.open()
        let store = try #require(first.store)
        try store.insertDocument(.manual("a", body: "hello"))
        try store.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v2-future')")
        }
        first.close()

        let opener = harness.opener()
        opener.open()
        #expect(opener.status == .readOnlySchemaNewer)
        #expect(!opener.canEdit)
        #expect(opener.canRead)
        let reopened = try #require(opener.store)
        #expect(try reopened.manualOverlays().count == 1)
        #expect(throws: NotesError.schemaNewer) { try reopened.insertDocument(.manual("b")) }
        #expect(throws: NotesError.schemaNewer) { try reopened.vacuum() }
        #expect(try reopened.manualOverlays().count == 1)
        let applied = try reopened.read { db in try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations") }
        #expect(Set(applied) == ["v1-notes", "v2-future"])
        #expect(harness.log.errors.contains { $0.contains("schemaNewer") })
    }

    @Test func theHiddenReadOnlyKeyBlocksEveryWriteAndLiftsAtOnce() throws {
        let harness = try NotesHarness()
        let opener = harness.opener()
        opener.open()
        let store = try #require(opener.store)
        let doc = try store.insertDocument(.manual("a", body: "one"))
        harness.settings.set(true, for: NotesSettingsKey.readOnly)
        #expect(!opener.canEdit)
        #expect(opener.canRead)

        #expect(throws: NotesError.readOnly) { try store.insertDocument(.manual("b")) }
        let revision = NewNoteRevision(
            docID: doc.docID, author: "human", state: .applied, body: "two", now: Date(),
            expectedHeadID: doc.revisionID)
        #expect(throws: NotesError.readOnly) { try store.appendRevision(revision) }
        #expect(throws: NotesError.readOnly) { try store.deleteDocument(doc.docID) }
        #expect(throws: NotesError.readOnly) { try store.detach(NoteKey(pluginID: "meetings", id: "x")) }
        let count = try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note_revision") }
        #expect(count == 1)
        #expect(try store.manualOverlays().count == 1)

        harness.settings.removeValue(for: NotesSettingsKey.readOnly)
        #expect(opener.canEdit)
        try store.appendRevision(revision)
        #expect(try store.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM note_revision") } == 2)
    }

    @Test func eraseDataRemovesTheKeychainItemAndTheFolderWithoutOpeningAnything() throws {
        let harness = try NotesHarness()
        let first = harness.opener()
        first.open()
        try #require(first.store).insertDocument(.manual("a"))
        first.close()
        let other = harness.directory.deletingLastPathComponent().appending(path: "meetings")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let opener = harness.opener()
        try opener.erase()
        #expect(harness.keychain.itemNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(opener.store == nil)
        try opener.erase()
    }

    @Test func aRecreatedKeyAfterEraseStartsAnEmptyLibrary() throws {
        let harness = try NotesHarness()
        let opener = harness.opener()
        opener.open()
        try #require(opener.store).insertDocument(.manual("a"))
        try opener.erase()
        opener.open()
        #expect(opener.status == .ready)
        #expect(opener.resetArchive == nil)
        #expect(try #require(opener.store).manualOverlays().isEmpty)
    }
}
