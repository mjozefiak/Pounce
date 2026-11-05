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
        /// A read error for one service only, so the legacy item can fail while the current one is absent.
        var readErrorsByService: [String: KeychainError] = [:]
        /// A delete error for one service only.
        var deleteErrorsByService: [String: KeychainError] = [:]
    }
    let state = Mutex(State())

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let result: Result<Data, KeychainError> = state.withLock { state in
            if let error = state.readError { return .failure(error) }
            if let error = state.readErrorsByService[service] { return .failure(error) }
            guard let data = state.items["\(service)/\(account)"] else { return .failure(.itemNotFound) }
            return .success(data)
        }
        return try result.get()
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        state.withLock { $0.items["\(service)/\(account)"] = data }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let failure = state.withLock { $0.deleteErrorsByService[service] }
        if let failure { throw failure }
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

    // MARK: Key copied from the service name used before the rename

    private static let current = "com.lintelapp.test"
    private static let legacy = "app.pounce.test"  // LEGACY-POUNCE

    private func bytes(_ keys: MasterKeys) -> Data {
        keys.derived(info: "blob").withUnsafeBytes { Data($0) }
    }

    @Test func aKeyUnderThePreviousServiceNameIsCopiedOnce() throws {
        let keychain = MemoryKeychain()
        let master = Data((0..<32).map { UInt8($0) })
        keychain.state.withLock { $0.items["\(Self.legacy)/master-key"] = master }
        let store = MasterKeyStore(service: Self.current, legacyService: Self.legacy, keychain: keychain)
        guard case .found(let keys) = store.lookup() else {
            Issue.record("expected the legacy key to be found")
            return
        }
        #expect(bytes(keys) == bytes(try #require(MasterKeys(master: master))))
        // The copy exists under the current name, the old item is left in place.
        keychain.state.withLock {
            #expect($0.items["\(Self.current)/master-key"] == master)
            #expect($0.items["\(Self.legacy)/master-key"] == master)
        }
        // A later lookup does not need the legacy service at all.
        let withoutLegacy = MasterKeyStore(service: Self.current, keychain: keychain)
        guard case .found(let again) = withoutLegacy.lookup() else {
            Issue.record("expected the copied key to be found")
            return
        }
        #expect(bytes(again) == bytes(keys))
    }

    @Test func theCurrentKeyWinsOverTheLegacyOne() throws {
        let keychain = MemoryKeychain()
        let current = Data(repeating: 1, count: 32)
        keychain.state.withLock {
            $0.items["\(Self.current)/master-key"] = current
            $0.items["\(Self.legacy)/master-key"] = Data(repeating: 2, count: 32)
        }
        let store = MasterKeyStore(service: Self.current, legacyService: Self.legacy, keychain: keychain)
        guard case .found(let keys) = store.lookup() else {
            Issue.record("expected .found")
            return
        }
        #expect(bytes(keys) == bytes(try #require(MasterKeys(master: current))))
    }

    @Test func missingMeansNeitherServiceHasAKey() {
        let store = MasterKeyStore(
            service: Self.current, legacyService: Self.legacy, keychain: MemoryKeychain())
        guard case .missing = store.lookup() else {
            Issue.record("expected .missing")
            return
        }
    }

    @Test func anUnreadableLegacyKeyIsNeverMissing() {
        // `.missing` is the only outcome that may reset a store, so a legacy item that exists but cannot be
        // read (denied prompt, locked keychain) must not look like "no key".
        for (error, expected) in [
            (KeychainError.accessDenied, KeyStoreError.denied), (.interactionNotAllowed, .locked),
        ] {
            let keychain = MemoryKeychain()
            keychain.state.withLock { $0.readErrorsByService[Self.legacy] = error }
            let store = MasterKeyStore(service: Self.current, legacyService: Self.legacy, keychain: keychain)
            guard case .failed(let failure) = store.lookup() else {
                Issue.record("expected .failed")
                continue
            }
            #expect(failure == expected)
            keychain.state.withLock { #expect($0.items["\(Self.current)/master-key"] == nil) }
        }
    }

    @Test func aMalformedLegacyKeyIsNotCopied() {
        let keychain = MemoryKeychain()
        keychain.state.withLock { $0.items["\(Self.legacy)/master-key"] = Data(count: 5) }
        let store = MasterKeyStore(service: Self.current, legacyService: Self.legacy, keychain: keychain)
        guard case .failed(.malformedKey) = store.lookup() else {
            Issue.record("expected .malformedKey")
            return
        }
        keychain.state.withLock { #expect($0.items["\(Self.current)/master-key"] == nil) }
    }

    @Test func eraseRemovesBothKeys() throws {
        let keychain = MemoryKeychain()
        keychain.state.withLock {
            $0.items["\(Self.current)/master-key"] = Data(repeating: 1, count: 32)
            $0.items["\(Self.legacy)/master-key"] = Data(repeating: 1, count: 32)
        }
        let store = MasterKeyStore(service: Self.current, legacyService: Self.legacy, keychain: keychain)
        try store.delete()
        keychain.state.withLock { #expect($0.items.isEmpty) }
        // Nothing left to delete is not an error either.
        try store.delete()
    }

    @Test func aLegacyKeyThatCannotBeRemovedIsReportedAfterTheCurrentOneIsGone() {
        let keychain = MemoryKeychain()
        let key = Data(repeating: 1, count: 32)
        keychain.state.withLock {
            $0.items["\(Self.current)/master-key"] = key
            $0.items["\(Self.legacy)/master-key"] = key
            $0.deleteErrorsByService[Self.legacy] = .accessDenied
        }
        let store = MasterKeyStore(service: Self.current, legacyService: Self.legacy, keychain: keychain)
        #expect(throws: KeyStoreError.denied) { try store.delete() }
        // The current key is erased anyway; the stubborn legacy one is what the caller is told about, because
        // the next lookup would copy it back.
        keychain.state.withLock {
            #expect($0.items["\(Self.current)/master-key"] == nil)
            #expect($0.items["\(Self.legacy)/master-key"] == key)
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
