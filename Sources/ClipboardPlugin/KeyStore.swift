import CryptoKit
import Foundation
import LintelKit
import LintelPersistence

/// The clipboard's working keys, derived with HKDF-SHA256 from the 32-byte master key in the Keychain
/// (spec: Data Model): `info = "sqlcipher"` for the database, `"blob"` for blob files and
/// `"content-hash"` for the `content_hash` HMAC. The bytes are never logged or described.
struct ClipKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let masterKeyByteCount = MasterKeys.masterKeyByteCount

    let database: DatabaseKey
    let blob: SymmetricKey
    let contentHash: SymmetricKey

    init(_ keys: MasterKeys) {
        database = keys.database
        blob = keys.derived(info: "blob")
        contentHash = keys.derived(info: "content-hash")
    }

    /// Returns `nil` unless the master key has exactly 32 bytes.
    init?(master: Data) {
        guard let keys = MasterKeys(master: master) else { return nil }
        self.init(keys)
    }

    var description: String { "ClipKeys(redacted)" }
    var debugDescription: String { description }
}

/// The clipboard's master key: `service = com.lintelapp.clipboard` in `MasterKeyStore`.
///
/// The three outcomes are kept apart on purpose: only `.missing` (`errSecItemNotFound`) may ever lead
/// to resetting the history. A locked keychain, a denied prompt or any other error leaves every file
/// alone and only disables recording until a retry succeeds.
struct KeyStore: Sendable {
    static let service = "com.lintelapp.clipboard"
    /// The service name before the app was renamed; the key is copied from it once.
    static let legacyService = "app.pounce.clipboard"  // LEGACY-POUNCE
    static let account = MasterKeyStore.account

    enum Lookup: Sendable {
        case found(ClipKeys)
        /// `errSecItemNotFound`: the key definitely does not exist.
        case missing
        case failed(KeyStoreError)
    }

    let keychain: any KeychainClient

    var master: MasterKeyStore {
        MasterKeyStore(service: Self.service, legacyService: Self.legacyService, keychain: keychain)
    }

    func lookup() -> Lookup {
        switch master.lookup() {
        case .found(let keys): .found(ClipKeys(keys))
        case .missing: .missing
        case .failed(let error): .failed(error)
        }
    }

    /// Generates 32 random bytes, stores them and returns the derived keys.
    func create() throws(KeyStoreError) -> ClipKeys {
        ClipKeys(try master.create())
    }

    /// Removes the master key ("Erase Data"). A key that is already gone is not an error.
    func delete() throws(KeyStoreError) {
        try master.delete()
    }
}
