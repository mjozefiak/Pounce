import CryptoKit
import Foundation
import GRDB
import LintelKit
import LintelPersistence
import Testing

@testable import ClipboardPlugin

@Suite struct ClipKeysTests {
    @Test func derivesSeparateSubKeysDeterministically() throws {
        let first = try testKeys(1)
        let again = try testKeys(1)
        let other = try testKeys(2)
        let blob = first.blob.withUnsafeBytes { Data($0) }
        let hash = first.contentHash.withUnsafeBytes { Data($0) }
        #expect(blob != hash)
        #expect(blob == again.blob.withUnsafeBytes { Data($0) })
        #expect(blob != other.blob.withUnsafeBytes { Data($0) })
        // The same HKDF parameters the spec names.
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(repeating: 1, count: 32)),
            info: Data("content-hash".utf8),
            outputByteCount: 32
        )
        #expect(hash == expected.withUnsafeBytes { Data($0) })
    }

    @Test func requiresAThirtyTwoByteMasterKeyAndIsRedacted() throws {
        #expect(ClipKeys(master: Data(count: 16)) == nil)
        let keys = try testKeys(0xEF)
        #expect(String(describing: keys) == "ClipKeys(redacted)")
        #expect(!String(reflecting: keys).lowercased().contains("efef"))
    }
}

@Suite struct KeyStoreTests {
    @Test func aMissingKeyIsReportedAsMissing() {
        let keychain = FakeKeychain()
        guard case .missing = KeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .missing")
            return
        }
    }

    @Test func aKeyFromBeforeTheRenameIsFoundAndCopied() throws {
        let keychain = FakeKeychain()
        let legacyKey = Data(repeating: 4, count: 32)
        keychain.state.withLock { $0.items["app.pounce.clipboard/master-key"] = legacyKey }  // LEGACY-POUNCE
        guard case .found(let keys) = KeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .found")
            return
        }
        #expect(
            keys.blob.withUnsafeBytes { Data($0) }
                == (try testKeys(4)).blob.withUnsafeBytes { Data($0) })
        keychain.state.withLock { #expect($0.items["com.lintelapp.clipboard/master-key"] == legacyKey) }
    }

    @Test func anUnreadableKeyFromBeforeTheRenameIsNotMissing() {
        let keychain = FakeKeychain()
        keychain.state.withLock {
            $0.items["app.pounce.clipboard/master-key"] = Data(repeating: 4, count: 32)  // LEGACY-POUNCE
        }
        // Reads fail for every service here; what matters is that the outcome is `.failed`, never `.missing`.
        keychain.state.withLock { $0.readError = .accessDenied }
        guard case .failed(.denied) = KeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .failed(.denied)")
            return
        }
    }

    @Test func createdKeysAreFoundAgain() throws {
        let keychain = FakeKeychain()
        let store = KeyStore(keychain: keychain)
        let created = try store.create()
        guard case .found(let found) = store.lookup() else {
            Issue.record("expected .found")
            return
        }
        #expect(found.blob.withUnsafeBytes { Data($0) } == created.blob.withUnsafeBytes { Data($0) })
        #expect(keychain.storedKeyCount == 1)
    }

    @Test(arguments: [
        (KeychainError.interactionNotAllowed, KeyStoreError.locked),
        (KeychainError.accessDenied, KeyStoreError.denied),
        (KeychainError.unexpected(status: -25300), KeyStoreError.unexpected(status: -25300)),
    ])
    func otherErrorsAreFailures(error: KeychainError, expected: KeyStoreError) {
        let keychain = FakeKeychain()
        keychain.state.withLock { $0.readError = error }
        guard case .failed(let failure) = KeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .failed")
            return
        }
        #expect(failure == expected)
    }

    @Test func aMalformedKeyIsAFailureNotAReset() {
        let keychain = FakeKeychain()
        keychain.state.withLock { $0.items["\(KeyStore.service)/\(KeyStore.account)"] = Data(count: 5) }
        guard case .failed(.malformedKey) = KeyStore(keychain: keychain).lookup() else {
            Issue.record("expected .malformedKey")
            return
        }
    }

    @Test func deletingAMissingKeyIsNotAnError() throws {
        try KeyStore(keychain: FakeKeychain()).delete()
    }
}

@Suite struct HistoryOpenerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func seedHistory(_ directory: URL, keychain: FakeKeychain) throws {
        let opener = HistoryOpener(directory: directory, keyStore: KeyStore(keychain: keychain))
        guard case .opened(let store, _) = try opener.open(now: now) else {
            Issue.record("expected the first open to succeed")
            return
        }
        try store.insert(draft("fake history entry"))
        try store.close()
    }

    @Test func theFirstOpenCreatesAKeyAndAnEmptyHistory() throws {
        let temporary = try TemporaryDirectory()
        let keychain = FakeKeychain()
        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: keychain))
        guard case .opened(let store, let archive) = try opener.open(now: now) else {
            Issue.record("expected .opened")
            return
        }
        #expect(archive == nil)
        #expect(try store.count() == 0)
        #expect(keychain.storedKeyCount == 1)
        try store.close()
        let attributes = try FileManager.default.attributesOfItem(atPath: opener.databaseURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let blobs = try FileManager.default.attributesOfItem(
            atPath: temporary.url.appending(path: ClipStore.blobsDirectoryName).path)
        #expect((blobs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func anExistingKeyOpensTheExistingHistory() throws {
        let temporary = try TemporaryDirectory()
        let keychain = FakeKeychain()
        try seedHistory(temporary.url, keychain: keychain)
        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: keychain))
        guard case .opened(let store, let archive) = try opener.open(now: now) else {
            Issue.record("expected .opened")
            return
        }
        #expect(archive == nil)
        #expect(try store.count() == 1)
        try store.close()
    }

    /// The only reset: the key is definitely gone while a database exists.
    @Test func onlyAMissingKeyArchivesAndResets() throws {
        let temporary = try TemporaryDirectory()
        let keychain = FakeKeychain()
        try seedHistory(temporary.url, keychain: keychain)
        try KeyStore(keychain: keychain).delete()

        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: keychain))
        guard case .opened(let store, let archive) = try opener.open(now: now) else {
            Issue.record("expected .opened")
            return
        }
        let archived = try #require(archive)
        #expect(archived.lastPathComponent == "clipboard.sqlite.unreadable-\(HistoryOpener.stamp(now))")
        #expect(FileManager.default.fileExists(atPath: archived.path))
        #expect(try store.count() == 0)
        try store.close()
    }

    @Test(arguments: [KeychainError.interactionNotAllowed, .accessDenied, .unexpected(status: -50)])
    func anyOtherKeychainErrorKeepsEveryFile(error: KeychainError) throws {
        let temporary = try TemporaryDirectory()
        let keychain = FakeKeychain()
        try seedHistory(temporary.url, keychain: keychain)
        let before = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).sorted()
        let original = try Data(contentsOf: temporary.url.appending(path: ClipStore.fileName))

        keychain.state.withLock { $0.readError = error }
        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: keychain))
        guard case .unavailable = try opener.open(now: now) else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).sorted() == before)
        #expect(try Data(contentsOf: temporary.url.appending(path: ClipStore.fileName)) == original)
        #expect(keychain.state.withLock { $0.adds } == 1)
    }

    @Test func aFailedKeyCreationDoesNotArchive() throws {
        let temporary = try TemporaryDirectory()
        let keychain = FakeKeychain()
        try seedHistory(temporary.url, keychain: keychain)
        try KeyStore(keychain: keychain).delete()
        keychain.state.withLock { $0.addError = .interactionNotAllowed }

        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: keychain))
        guard case .unavailable(.locked) = try opener.open(now: now) else {
            Issue.record("expected .unavailable(.locked)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: opener.databaseURL.path))
    }

    @Test func aWrongKeyThrowsWithoutDeletingAnything() throws {
        let temporary = try TemporaryDirectory()
        let keychain = FakeKeychain()
        try seedHistory(temporary.url, keychain: keychain)
        let other = FakeKeychain()
        other.state.withLock {
            $0.items["\(KeyStore.service)/\(KeyStore.account)"] = Data(repeating: 9, count: 32)
        }
        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: other))
        #expect(throws: DatabaseError.self) { _ = try opener.open(now: now) }
        #expect(FileManager.default.fileExists(atPath: opener.databaseURL.path))
    }

    @Test func archivesAreKeptThirtyDays() throws {
        let temporary = try TemporaryDirectory()
        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: FakeKeychain()))
        let recent = "clipboard.sqlite.unreadable-\(HistoryOpener.stamp(now.addingTimeInterval(-29 * 86_400)))"
        let old = "clipboard.sqlite.unreadable-\(HistoryOpener.stamp(now.addingTimeInterval(-31 * 86_400)))"
        let oldBlobs = "blobs.unreadable-\(HistoryOpener.stamp(now.addingTimeInterval(-31 * 86_400)))"
        for name in [recent, old, "clipboard.sqlite"] {
            FileManager.default.createFile(atPath: temporary.url.appending(path: name).path, contents: Data())
        }
        try FileManager.default.createDirectory(
            at: temporary.url.appending(path: oldBlobs), withIntermediateDirectories: true)
        #expect(opener.purgeOldArchives(now: now) == 2)
        let left = try FileManager.default.contentsOfDirectory(atPath: temporary.url.path).sorted()
        #expect(left == ["clipboard.sqlite", recent].sorted())
    }
}

/// A clipboard database written by the release before the key logic moved to `LintelPersistence`
/// (`Fixtures/previous-release`, master key = 32 bytes of 0x07) still opens, with the same Keychain item.
@Suite struct PreviousReleaseCompatibilityTests {
    private func copyFixture() throws -> TemporaryDirectory {
        let temporary = try TemporaryDirectory()
        let fixture = try #require(Bundle.module.url(forResource: "Fixtures/previous-release", withExtension: nil))
        try FileManager.default.copyItem(
            at: fixture.appending(path: "clipboard.sqlite"), to: temporary.url.appending(path: "clipboard.sqlite"))
        return temporary
    }

    private func keychainWithOldKey() throws -> FakeKeychain {
        let keychain = FakeKeychain()
        try keychain.addGenericPassword(
            Data(repeating: 7, count: 32), service: "com.lintelapp.clipboard", account: "master-key")
        return keychain
    }

    @Test func theDatabaseOfThePreviousReleaseOpensAndKeepsItsEntry() throws {
        let temporary = try copyFixture()
        let keychain = try keychainWithOldKey()
        let opener = HistoryOpener(directory: temporary.url, keyStore: KeyStore(keychain: keychain))
        guard case .opened(let store, let archive) = try opener.open(now: Date()) else {
            Issue.record("expected .opened")
            return
        }
        #expect(archive == nil)
        #expect(try store.count() == 1)
        #expect(try store.recent(limit: 5).first?.previewText == "entry written by the previous release")
        #expect(keychain.storedKeyCount == 1)
        try store.close()
    }

    @Test func theServiceAndAccountAreUnchanged() {
        #expect(KeyStore.service == "com.lintelapp.clipboard")
        #expect(KeyStore.account == "master-key")
    }
}
