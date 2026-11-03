import CryptoKit
import Foundation
import PounceKit
import PouncePersistence

/// The meetings library's working keys, derived with HKDF-SHA256 from the 32-byte master key in the Keychain
/// (spec: Data Model): `info = "sqlcipher"` for the database and `info = "spool"` for the temporary audio
/// files. The bytes are never logged or described.
struct MeetingKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let spoolInfo = "spool"

    let database: DatabaseKey
    /// The spool key. Each spool file gets its own sub-key from `master.derived(info:)` (step 1.3).
    let spool: SymmetricKey
    /// The keys themselves, for the per-file spool sub-keys.
    let master: MasterKeys

    init(_ keys: MasterKeys) {
        database = keys.database
        spool = keys.derived(info: Self.spoolInfo)
        master = keys
    }

    var description: String { "MeetingKeys(redacted)" }
    var debugDescription: String { description }
}

/// The meetings master key: `service = app.pounce.meetings` in `MasterKeyStore`.
///
/// The three outcomes are kept apart on purpose: only `.missing` (`errSecItemNotFound`) may ever lead to
/// resetting the library. A locked keychain, a denied prompt or any other error leaves every file alone and
/// only disables the library (and recording) until a retry succeeds.
struct MeetingKeyStore: Sendable {
    static let service = "app.pounce.meetings"

    enum Lookup: Sendable {
        case found(MeetingKeys)
        /// `errSecItemNotFound`: the key definitely does not exist.
        case missing
        case failed(KeyStoreError)
    }

    let keychain: any KeychainClient

    var master: MasterKeyStore { MasterKeyStore(service: Self.service, keychain: keychain) }

    func lookup() -> Lookup {
        switch master.lookup() {
        case .found(let keys): .found(MeetingKeys(keys))
        case .missing: .missing
        case .failed(let error): .failed(error)
        }
    }

    /// Removes the Keychain item ("Erase Data"). A key that is already gone is not an error.
    func delete() throws(KeyStoreError) {
        try master.delete()
    }
}
