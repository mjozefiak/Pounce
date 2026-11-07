import Foundation
import LintelKit
import LintelPersistence

/// The notes library's key: the database key derived with HKDF-SHA256 (`info = "sqlcipher"`) from the 32-byte
/// master key in the Keychain. The bytes are never logged or described.
struct NotesKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let database: DatabaseKey

    init(_ keys: MasterKeys) {
        database = keys.database
    }

    var description: String { "NotesKeys(redacted)" }
    var debugDescription: String { description }
}

/// The notes master key: `service = com.lintelapp.notes` in `MasterKeyStore` (no legacy service: Notes is newer
/// than the rename).
///
/// The three outcomes stay apart on purpose: only `.missing` (`errSecItemNotFound`) may ever lead to resetting
/// the library. A locked keychain, a denied prompt or any other error leaves every file alone.
struct NotesKeyStore: Sendable {
    static let service = "com.lintelapp.notes"

    enum Lookup: Sendable {
        case found(NotesKeys)
        case missing
        case failed(KeyStoreError)
    }

    let keychain: any KeychainClient

    var master: MasterKeyStore {
        MasterKeyStore(service: Self.service, keychain: keychain)
    }

    func lookup() -> Lookup {
        switch master.lookup() {
        case .found(let keys): .found(NotesKeys(keys))
        case .missing: .missing
        case .failed(let error): .failed(error)
        }
    }

    /// Removes the Keychain item ("Erase Data"). A key that is already gone is not an error.
    func delete() throws(KeyStoreError) {
        try master.delete()
    }
}
