import Foundation

// Dependency-injection ports. The app shell provides the system implementations; tests and QA mode
// provide in-memory ones. Plugins only ever talk to these protocols. Later phases extend a port
// additively: a new requirement always comes with a default in a protocol extension.

/// Keychain errors that callers must tell apart. Only `itemNotFound` may ever lead to resetting data;
/// every other error leaves data untouched.
public enum KeychainError: Error, Hashable, Sendable {
    /// `errSecItemNotFound`: the item definitely does not exist.
    case itemNotFound
    /// `errSecInteractionNotAllowed`: the keychain is locked; retry later.
    case interactionNotAllowed
    /// The user denied access or cancelled the prompt.
    case accessDenied
    /// Any other `OSStatus`.
    case unexpected(status: Int32)
}

/// Generic-password access to the file-based login keychain.
public protocol KeychainClient: Sendable {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data
    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError)
    func deleteGenericPassword(service: String, account: String) throws(KeychainError)
}

/// Access to the pasteboard the clipboard history watches.
public protocol PasteboardClient: Sendable {
    /// Increments whenever the pasteboard contents change.
    @MainActor var changeCount: Int { get }
    @MainActor func string() -> String?
    /// Replaces the contents with a string and returns the new `changeCount`.
    @MainActor @discardableResult func setString(_ string: String) -> Int
}

/// Why a synthetic paste could not be posted.
public enum EventPosterError: Error, Hashable, Sendable {
    /// Accessibility permission is missing.
    case notPermitted
    /// Secure Event Input is on, so the keystroke would not arrive.
    case secureEventInput
}

/// Posts the paste shortcut into the frontmost app.
public protocol EventPoster: Sendable {
    @MainActor func postPaste() throws(EventPosterError)
}

/// The parts of `NSWorkspace` plugins use.
public protocol WorkspaceClient: Sendable {
    @MainActor var frontmostApplicationPID: pid_t? { get }
    @MainActor func open(_ url: URL) async throws
    @MainActor func revealInFinder(_ urls: [URL])
}

/// Usage statistics for one item, read from `ranking.sqlite`.
public struct UsageStats: Hashable, Sendable {
    public let frecency: Double
    public let lastUsedAt: Date?
    public let useCount: Int
    /// How often the current query prefix led to choosing this item.
    public let queryAssociationCount: Int

    public init(frecency: Double, lastUsedAt: Date?, useCount: Int, queryAssociationCount: Int) {
        self.frecency = frecency
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.queryAssociationCount = queryAssociationCount
    }

    public static let unused = UsageStats(
        frecency: 0,
        lastUsedAt: nil,
        useCount: 0,
        queryAssociationCount: 0
    )
}

/// Records and reads ranking signals in `ranking.sqlite`. Nothing from the clipboard is ever recorded
/// here.
public protocol UsageRecorder: Sendable {
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats]
}

/// Reads permission state with preflight APIs, never by triggering a prompt.
public protocol PermissionsReader: Sendable {
    @MainActor func status(of permission: Permission) -> PermissionStatus
}
