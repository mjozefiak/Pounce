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

/// How to open an application (mirrors the parts of `NSWorkspace.OpenConfiguration` plugins use).
public struct ApplicationOpenOptions: Hashable, Sendable {
    /// Bring the app to the front.
    public var activates: Bool
    /// Add the app to the Recent Items menu.
    public var addsToRecentItems: Bool
    /// Ask the user (for example about a quarantined app) instead of failing silently.
    public var promptsUserIfNeeded: Bool
    /// The bundle identifier to hand activation to before opening, so the app may come to the front while
    /// Pounce never activates itself (macOS cooperative activation).
    public var yieldsActivationTo: String?

    public init(
        activates: Bool = true,
        addsToRecentItems: Bool = true,
        promptsUserIfNeeded: Bool = true,
        yieldsActivationTo: String? = nil
    ) {
        self.activates = activates
        self.addsToRecentItems = addsToRecentItems
        self.promptsUserIfNeeded = promptsUserIfNeeded
        self.yieldsActivationTo = yieldsActivationTo
    }
}

/// The parts of `NSWorkspace` plugins use.
public protocol WorkspaceClient: Sendable {
    @MainActor var frontmostApplicationPID: pid_t? { get }
    @MainActor func open(_ url: URL) async throws
    @MainActor func revealInFinder(_ urls: [URL])
    /// Opens (or activates) the application bundle at `url`. Added in Phase 1; the default opens it like
    /// any other URL.
    @MainActor func openApplication(at url: URL, options: ApplicationOpenOptions) async throws
}

extension WorkspaceClient {
    @MainActor public func openApplication(at url: URL, options: ApplicationOpenOptions) async throws {
        try await open(url)
    }
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
    /// One plugin's items with recorded uses, highest decayed frecency at `now` first. Sources use it to
    /// answer an empty query with recently used items. Added in Phase 1; the default knows no items.
    func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey]
    /// Deletes every usage statistic and query association of one plugin's items (keys `<id>:…`), for
    /// "Erase Data". Added in Phase 1; the default keeps nothing, so it has nothing to delete.
    func removeAll(pluginID: PluginID) async throws
}

extension UsageRecorder {
    public func mostUsed(pluginID: PluginID, limit: Int, now: Date) async throws -> [ItemKey] { [] }
    public func removeAll(pluginID: PluginID) async throws {}
}

/// Reads permission state with preflight APIs, never by triggering a prompt.
public protocol PermissionsReader: Sendable {
    @MainActor func status(of permission: Permission) -> PermissionStatus
}

/// A value in the settings store. Settings only ever hold these types, so every store is `Sendable`
/// without bridging `Any`.
public enum SettingValue: Hashable, Sendable {
    case bool(Bool)
    case integer(Int)
    case string(String)
    case stringArray([String])
}

/// Key-value storage behind `PluginSettings` and the host's `plugins.<id>.enabled` toggles. The app
/// stores settings in `UserDefaults.standard`; tests and QA mode use an in-memory store, so they never
/// create or change a defaults domain on the tester's Mac.
public protocol SettingsStore: Sendable {
    func value(forKey key: String) -> SettingValue?
    /// Stores the value; `nil` removes the key.
    func setValue(_ value: SettingValue?, forKey key: String)
}
