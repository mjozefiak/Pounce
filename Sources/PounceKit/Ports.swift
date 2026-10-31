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

/// One representation of a pasteboard item: its type identifier and its bytes. Added in Phase 2.
public struct PasteboardRepresentation: Hashable, Sendable {
    /// A uniform type identifier (`public.utf8-plain-text`, `public.png`, `public.file-url`, …).
    public let type: String
    public let data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }

    /// `public.utf8-plain-text`.
    public static let plainTextType = "public.utf8-plain-text"
}

/// One item on the pasteboard with its representations, in the order the writer offered them. Added in
/// Phase 2.
public struct PasteboardItem: Hashable, Sendable {
    public let representations: [PasteboardRepresentation]

    public init(representations: [PasteboardRepresentation]) {
        self.representations = representations
    }

    public var types: [String] { representations.map(\.type) }

    /// The bytes of the first representation of `type`.
    public func data(for type: String) -> Data? {
        representations.first { $0.type == type }?.data
    }
}

/// Everything one read of the pasteboard found. Added in Phase 2.
public struct PasteboardContents: Hashable, Sendable {
    /// The `changeCount` the read started at. The caller compares it again after the read and drops the
    /// contents when the pasteboard changed in between.
    public let changeCount: Int
    public let items: [PasteboardItem]
    /// True when the representations together exceeded the byte limit of the read. The items are then
    /// incomplete and must not be stored.
    public let exceedsLimit: Bool

    public init(changeCount: Int, items: [PasteboardItem], exceedsLimit: Bool = false) {
        self.changeCount = changeCount
        self.items = items
        self.exceedsLimit = exceedsLimit
    }

    /// The total size of every representation.
    public var byteCount: Int {
        items.reduce(0) { total, item in total + item.representations.reduce(0) { $0 + $1.data.count } }
    }
}

/// Whether the system lets the app read the general pasteboard without asking (macOS pasteboard
/// privacy, `NSPasteboard.accessBehavior`). Added in Phase 2.
public enum PasteboardAccess: String, Hashable, Sendable, CaseIterable {
    /// The user allowed Pounce to always read the pasteboard.
    case alwaysAllow
    /// The system default: no explicit choice for Pounce.
    case systemDefault
    /// The system asks the user every time a program reads the pasteboard.
    case ask
    /// The user denied Pounce access to the pasteboard.
    case alwaysDeny
}

/// Access to the pasteboard the clipboard history watches.
///
/// `NSPasteboard` is not documented as safe off the main thread (spike 2.2,
/// `docs/decisions/0002-pasteboard-reads.md`), so every member is main-actor isolated; callers copy
/// what they read and process it in the background.
public protocol PasteboardClient: Sendable {
    /// Increments whenever the pasteboard contents change.
    @MainActor var changeCount: Int { get }
    @MainActor func string() -> String?
    /// Replaces the contents with a string and returns the new `changeCount`.
    @MainActor @discardableResult func setString(_ string: String) -> Int
    /// Every type currently on the pasteboard, read without any data (for example the nspasteboard.org
    /// marker types). Added in Phase 2; the default reports the plain-text type when there is a string.
    @MainActor func types() -> [String]
    /// Reads every item with the representations whose type `includes` accepts; the data of any other
    /// type is never requested (it may be large or produced lazily by the writing app). Stops reading
    /// once the representations exceed `maxBytes` and reports `exceedsLimit`. Returns `nil` when the
    /// pasteboard is empty. Added in Phase 2; the default reads the string only.
    @MainActor func readContents(maxBytes: Int, including includes: (String) -> Bool) -> PasteboardContents?
    /// Replaces the contents with these items and returns the new `changeCount`. Added in Phase 2; the
    /// default writes the first plain-text representation through `setString`.
    @MainActor @discardableResult func write(_ items: [PasteboardItem]) -> Int
    /// The pasteboard privacy setting for Pounce. Added in Phase 2; the default is `.alwaysAllow`.
    @MainActor var accessBehavior: PasteboardAccess { get }
}

extension PasteboardClient {
    @MainActor public func types() -> [String] {
        string() == nil ? [] : [PasteboardRepresentation.plainTextType]
    }

    /// Reads every type.
    @MainActor public func readContents(maxBytes: Int) -> PasteboardContents? {
        readContents(maxBytes: maxBytes) { _ in true }
    }

    @MainActor public func readContents(maxBytes: Int, including includes: (String) -> Bool) -> PasteboardContents? {
        guard includes(PasteboardRepresentation.plainTextType), let string = string() else { return nil }
        let data = Data(string.utf8)
        guard data.count <= maxBytes else {
            return PasteboardContents(changeCount: changeCount, items: [], exceedsLimit: true)
        }
        let item = PasteboardItem(representations: [
            PasteboardRepresentation(type: PasteboardRepresentation.plainTextType, data: data)
        ])
        return PasteboardContents(changeCount: changeCount, items: [item])
    }

    @MainActor @discardableResult public func write(_ items: [PasteboardItem]) -> Int {
        let text = items.lazy.compactMap { $0.data(for: PasteboardRepresentation.plainTextType) }.first
        return setString(text.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }

    @MainActor public var accessBehavior: PasteboardAccess { .alwaysAllow }
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

/// A running application as plugins see it. Added in Phase 2.
public struct RunningApplication: Hashable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    /// The localized name shown to the user.
    public let name: String?

    public init(processIdentifier: pid_t, bundleIdentifier: String? = nil, name: String? = nil) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.name = name
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
    /// The frontmost application with its bundle identifier and name. Added in Phase 2; the default
    /// knows only the process identifier.
    @MainActor var frontmostApplication: RunningApplication? { get }
    /// The application with this process identifier, or `nil` when it is no longer running. Added in
    /// Phase 2; the default assumes it still runs.
    @MainActor func runningApplication(processIdentifier: pid_t) -> RunningApplication?
    /// Yields each time the user's session becomes active again (switching back to this user, unlocking
    /// the screen), for example to retry a locked Keychain. Added in Phase 2; the default never yields.
    func sessionActivations() -> AsyncStream<Void>
}

extension WorkspaceClient {
    @MainActor public func openApplication(at url: URL, options: ApplicationOpenOptions) async throws {
        try await open(url)
    }

    @MainActor public var frontmostApplication: RunningApplication? {
        frontmostApplicationPID.map { RunningApplication(processIdentifier: $0) }
    }

    @MainActor public func runningApplication(processIdentifier: pid_t) -> RunningApplication? {
        RunningApplication(processIdentifier: processIdentifier)
    }

    public func sessionActivations() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
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
