import CryptoKit
import Foundation
import PounceKit
import PouncePersistence

/// The clipboard's working keys, derived with HKDF-SHA256 from the 32-byte master key in the Keychain
/// (spec: Data Model): `info = "sqlcipher"` for the database, `"blob"` for blob files and
/// `"content-hash"` for the `content_hash` HMAC. The bytes are never logged or described.
struct ClipKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    static let masterKeyByteCount = 32

    let database: DatabaseKey
    let blob: SymmetricKey
    let contentHash: SymmetricKey

    /// Returns `nil` unless the master key has exactly 32 bytes.
    init?(master: Data) {
        guard master.count == Self.masterKeyByteCount else { return nil }
        let input = SymmetricKey(data: master)
        let databaseBytes = Self.derive(input, info: "sqlcipher").withUnsafeBytes { Data($0) }
        guard let database = DatabaseKey(rawBytes: databaseBytes) else { return nil }
        self.database = database
        self.blob = Self.derive(input, info: "blob")
        self.contentHash = Self.derive(input, info: "content-hash")
    }

    var description: String { "ClipKeys(redacted)" }
    var debugDescription: String { description }

    private static func derive(_ input: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: input, info: Data(info.utf8), outputByteCount: 32)
    }
}

/// Reads and creates the master key in the file-based login keychain through `KeychainClient`
/// (`kSecClassGenericPassword`, `service = app.pounce.clipboard`).
///
/// The three outcomes are kept apart on purpose: only `.missing` (`errSecItemNotFound`) may ever lead
/// to resetting the history. A locked keychain, a denied prompt or any other error leaves every file
/// alone and only disables recording until a retry succeeds.
struct KeyStore: Sendable {
    static let service = "app.pounce.clipboard"
    static let account = "master-key"

    enum Lookup: Sendable {
        case found(ClipKeys)
        /// `errSecItemNotFound`: the key definitely does not exist.
        case missing
        case failed(KeyStoreError)
    }

    let keychain: any KeychainClient

    func lookup() -> Lookup {
        do {
            let master = try keychain.readGenericPassword(service: Self.service, account: Self.account)
            guard let keys = ClipKeys(master: master) else { return .failed(.malformedKey) }
            return .found(keys)
        } catch .itemNotFound {
            return .missing
        } catch {
            return .failed(KeyStoreError(error))
        }
    }

    /// Generates 32 random bytes, stores them and returns the derived keys.
    func create() throws(KeyStoreError) -> ClipKeys {
        var master = Data(count: ClipKeys.masterKeyByteCount)
        let status = master.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, ClipKeys.masterKeyByteCount, base)
        }
        guard status == errSecSuccess else { throw .unexpected(status: status) }
        guard let keys = ClipKeys(master: master) else { throw .malformedKey }
        do {
            try keychain.addGenericPassword(master, service: Self.service, account: Self.account)
        } catch {
            throw KeyStoreError(error)
        }
        return keys
    }

    /// Removes the master key ("Erase Data"). A key that is already gone is not an error.
    func delete() throws(KeyStoreError) {
        do {
            try keychain.deleteGenericPassword(service: Self.service, account: Self.account)
        } catch .itemNotFound {
            return
        } catch {
            throw KeyStoreError(error)
        }
    }
}

/// Why the clipboard key is unavailable. None of these deletes anything.
enum KeyStoreError: Error, Hashable, Sendable {
    /// `errSecInteractionNotAllowed`: the keychain is locked. Retried when the session becomes active
    /// and when the clipboard mode opens.
    case locked
    /// The user denied access or cancelled the prompt.
    case denied
    /// The stored item is not a 32-byte key. Never "repaired" by replacing it: that would make the
    /// existing history unreadable.
    case malformedKey
    case unexpected(status: Int32)

    init(_ error: KeychainError) {
        switch error {
        case .interactionNotAllowed: self = .locked
        case .accessDenied: self = .denied
        case .itemNotFound: self = .unexpected(status: errSecItemNotFound)
        case .unexpected(let status): self = .unexpected(status: status)
        }
    }
}
