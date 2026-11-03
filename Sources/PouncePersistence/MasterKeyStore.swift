import CryptoKit
import Foundation
import PounceKit

/// The working keys of one encrypted store, derived with HKDF-SHA256 from the 32-byte master key in the
/// Keychain (spec: Data Model): `info = "sqlcipher"` for the database, and any other `info` a plugin asks for
/// (the clipboard uses `"blob"` and `"content-hash"`). The bytes are never logged or described.
public struct MasterKeys: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let masterKeyByteCount = 32

    public let database: DatabaseKey
    private let input: SymmetricKey

    /// Returns `nil` unless the master key has exactly 32 bytes.
    public init?(master: Data) {
        guard master.count == Self.masterKeyByteCount else { return nil }
        let input = SymmetricKey(data: master)
        let databaseBytes = Self.derive(input, info: "sqlcipher").withUnsafeBytes { Data($0) }
        guard let database = DatabaseKey(rawBytes: databaseBytes) else { return nil }
        self.input = input
        self.database = database
    }

    /// A further 32-byte key for another purpose.
    public func derived(info: String) -> SymmetricKey {
        Self.derive(input, info: info)
    }

    public var description: String { "MasterKeys(redacted)" }
    public var debugDescription: String { description }

    private static func derive(_ input: SymmetricKey, info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: input, info: Data(info.utf8), outputByteCount: 32)
    }
}

/// Why a master key is unavailable. None of these deletes anything.
public enum KeyStoreError: Error, Hashable, Sendable {
    /// `errSecInteractionNotAllowed`: the keychain is locked. Retried later.
    case locked
    /// The user denied access or cancelled the prompt.
    case denied
    /// The stored item is not a 32-byte key. Never "repaired" by replacing it: that would make the
    /// existing data unreadable.
    case malformedKey
    case unexpected(status: Int32)

    public init(_ error: KeychainError) {
        switch error {
        case .interactionNotAllowed: self = .locked
        case .accessDenied: self = .denied
        case .itemNotFound: self = .unexpected(status: errSecItemNotFound)
        case .unexpected(let status): self = .unexpected(status: status)
        }
    }
}

/// Reads and creates a plugin's master key in the file-based login keychain through `KeychainClient`
/// (`kSecClassGenericPassword`, `account = "master-key"`, `service` per plugin: `app.pounce.clipboard`,
/// `app.pounce.dictation`).
///
/// The three outcomes are kept apart on purpose: only `.missing` (`errSecItemNotFound`) may ever lead to
/// resetting a store. A locked keychain, a denied prompt or any other error leaves every file alone and only
/// disables the store until a retry succeeds.
public struct MasterKeyStore: Sendable {
    public static let account = "master-key"

    public enum Lookup: Sendable {
        case found(MasterKeys)
        /// `errSecItemNotFound`: the key definitely does not exist.
        case missing
        case failed(KeyStoreError)
    }

    public let service: String
    public let keychain: any KeychainClient

    public init(service: String, keychain: any KeychainClient) {
        self.service = service
        self.keychain = keychain
    }

    public func lookup() -> Lookup {
        do {
            let master = try keychain.readGenericPassword(service: service, account: Self.account)
            guard let keys = MasterKeys(master: master) else { return .failed(.malformedKey) }
            return .found(keys)
        } catch .itemNotFound {
            return .missing
        } catch {
            return .failed(KeyStoreError(error))
        }
    }

    /// Generates 32 random bytes, stores them and returns the derived keys.
    public func create() throws(KeyStoreError) -> MasterKeys {
        var master = Data(count: MasterKeys.masterKeyByteCount)
        let status = master.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return SecRandomCopyBytes(kSecRandomDefault, MasterKeys.masterKeyByteCount, base)
        }
        guard status == errSecSuccess else { throw .unexpected(status: status) }
        guard let keys = MasterKeys(master: master) else { throw .malformedKey }
        do {
            try keychain.addGenericPassword(master, service: service, account: Self.account)
        } catch {
            throw KeyStoreError(error)
        }
        return keys
    }

    /// Removes the master key ("Erase Data"). A key that is already gone is not an error.
    public func delete() throws(KeyStoreError) {
        do {
            try keychain.deleteGenericPassword(service: service, account: Self.account)
        } catch .itemNotFound {
            return
        } catch {
            throw KeyStoreError(error)
        }
    }
}
