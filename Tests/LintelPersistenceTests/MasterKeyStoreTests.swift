import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import LintelKit
@testable import LintelPersistence

private final class MemoryKeychain: KeychainClient {
    struct State {
        var items: [String: Data] = [:]
        var readError: KeychainError?
    }
    let state = Mutex(State())

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let result: Result<Data, KeychainError> = state.withLock { state in
            if let error = state.readError { return .failure(error) }
            guard let data = state.items["\(service)/\(account)"] else { return .failure(.itemNotFound) }
            return .success(data)
        }
        return try result.get()
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        state.withLock { $0.items["\(service)/\(account)"] = data }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let found = state.withLock { $0.items.removeValue(forKey: "\(service)/\(account)") != nil }
        if !found { throw .itemNotFound }
    }
}

@Suite struct MasterKeyStoreTests {
    @Test func derivationMatchesTheOriginalHKDFByteForByte() throws {
        let master = Data(repeating: 7, count: 32)
        let keys = try #require(MasterKeys(master: master))
        let input = SymmetricKey(data: master)
        for info in ["blob", "content-hash"] {
            let expected = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: input, info: Data(info.utf8), outputByteCount: 32)
            let actual = keys.derived(info: info)
            #expect(expected.withUnsafeBytes { Data($0) } == actual.withUnsafeBytes { Data($0) })
        }
        // The database key is the "sqlcipher" derivation: a database made with it opens with MasterKeys.
        #expect(String(describing: keys) == "MasterKeys(redacted)")
        #expect(MasterKeys(master: Data(count: 16)) == nil)
    }

    @Test func eachServiceHasItsOwnKey() throws {
        let keychain = MemoryKeychain()
        let clipboard = MasterKeyStore(service: "com.lintelapp.clipboard", keychain: keychain)
        let dictation = MasterKeyStore(service: "com.lintelapp.dictation", keychain: keychain)
        guard case .missing = dictation.lookup() else {
            Issue.record("expected .missing")
            return
        }
        _ = try clipboard.create()
        guard case .missing = dictation.lookup() else {
            Issue.record("the dictation key must not exist yet")
            return
        }
        _ = try dictation.create()
        #expect(
            keychain.state.withLock { Set($0.items.keys) } == [
                "com.lintelapp.clipboard/master-key", "com.lintelapp.dictation/master-key",
            ])
        try dictation.delete()
        try dictation.delete()
        guard case .found = clipboard.lookup() else {
            Issue.record("deleting one key must leave the other")
            return
        }
    }

    @Test func onlyAMissingItemIsMissing() {
        let keychain = MemoryKeychain()
        let store = MasterKeyStore(service: "s", keychain: keychain)
        for (error, expected) in [
            (KeychainError.interactionNotAllowed, KeyStoreError.locked), (.accessDenied, .denied),
            (.unexpected(status: -1), .unexpected(status: -1)),
        ] {
            keychain.state.withLock { $0.readError = error }
            guard case .failed(let failure) = store.lookup() else {
                Issue.record("expected .failed")
                continue
            }
            #expect(failure == expected)
        }
        keychain.state.withLock {
            $0.readError = nil
            $0.items["s/master-key"] = Data(count: 5)
        }
        guard case .failed(.malformedKey) = store.lookup() else {
            Issue.record("expected .malformedKey")
            return
        }
    }
}

@Suite struct EncryptedDatabaseOpenerTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lintel-opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func opener(_ url: URL, _ keychain: MemoryKeychain) -> EncryptedDatabaseOpener {
        EncryptedDatabaseOpener(
            directory: url, databaseFileName: "x.sqlite", extraNames: ["extras"],
            keyStore: MasterKeyStore(service: "com.lintelapp.test", keychain: keychain))
    }

    @Test func aMissingKeyArchivesTheOldFilesAndOpensAnEmptyStore() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old".utf8).write(to: url.appending(path: "x.sqlite"))
        try FileManager.default.createDirectory(at: url.appending(path: "extras"), withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let outcome = try opener(url, MemoryKeychain()).open(now: now) { _ in "store" }
        guard case .opened("store", let archive) = outcome else {
            Issue.record("expected .opened")
            return
        }
        let stamp = EncryptedDatabaseOpener.stamp(now)
        #expect(archive?.lastPathComponent == "x.sqlite.unreadable-\(stamp)")
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "extras.unreadable-\(stamp)").path))
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "x.sqlite").path))
    }

    @Test func anotherKeychainErrorTouchesNothing() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old".utf8).write(to: url.appending(path: "x.sqlite"))
        let keychain = MemoryKeychain()
        keychain.state.withLock { $0.readError = .interactionNotAllowed }
        let outcome = try opener(url, keychain).open(now: Date()) { _ in "store" }
        guard case .unavailable(.locked) = outcome else {
            Issue.record("expected .unavailable(.locked)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "x.sqlite").path))
    }

    @Test func oldArchivesArePurgedAfterThirtyDays() throws {
        let url = try directory()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-31 * 86_400)
        let recent = now.addingTimeInterval(-5 * 86_400)
        for date in [old, recent] {
            try Data().write(to: url.appending(path: "x.sqlite.unreadable-\(EncryptedDatabaseOpener.stamp(date))"))
        }
        #expect(opener(url, MemoryKeychain()).purgeOldArchives(now: now) == 1)
    }
}
