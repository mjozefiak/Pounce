import Foundation
import PounceKit
import Security
import Synchronization

/// Generic passwords in the file-based login keychain (not the data-protection keychain, which needs a
/// provisioning profile a self-signed app cannot get). The default ACL trusts the app that created the
/// item, which survives updates because the designated requirement stays the same.
nonisolated struct SystemKeychainClient: KeychainClient {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainStatus.error(for: status) }
        guard let data = result as? Data else { throw KeychainError.unexpected(status: errSecDecode) }
        return data
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainStatus.error(for: status) }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess else { throw KeychainStatus.error(for: status) }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }
}

/// Maps Security framework statuses to the errors callers must tell apart.
nonisolated enum KeychainStatus {
    static func error(for status: OSStatus) -> KeychainError {
        switch status {
        case errSecItemNotFound:
            .itemNotFound
        case errSecInteractionNotAllowed:
            .interactionNotAllowed
        case errSecAuthFailed, errSecUserCanceled:
            .accessDenied
        default:
            .unexpected(status: status)
        }
    }
}

/// A keychain that lives only in memory. Used by tests and QA mode, so rebuilt ad-hoc binaries never
/// touch (or prompt for) the real login keychain.
nonisolated final class InMemoryKeychainClient: KeychainClient {
    private struct ItemID: Hashable {
        let service: String
        let account: String
    }

    private let items = Mutex<[ItemID: Data]>([:])

    init() {}

    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data {
        let data = items.withLock { $0[ItemID(service: service, account: account)] }
        guard let data else { throw KeychainError.itemNotFound }
        return data
    }

    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {
        let added = items.withLock { items -> Bool in
            let id = ItemID(service: service, account: account)
            guard items[id] == nil else { return false }
            items[id] = data
            return true
        }
        guard added else { throw KeychainError.unexpected(status: errSecDuplicateItem) }
    }

    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {
        let removed = items.withLock { $0.removeValue(forKey: ItemID(service: service, account: account)) }
        guard removed != nil else { throw KeychainError.itemNotFound }
    }
}
