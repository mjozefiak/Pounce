import Foundation
import os

/// A plugin's settings: `UserDefaults` keys under the `plugins.<id>.` prefix.
public struct PluginSettings: Sendable {
    public let pluginID: PluginID
    private let storage: DefaultsStorage

    public init(pluginID: PluginID, defaults: UserDefaults) {
        self.pluginID = pluginID
        self.storage = DefaultsStorage(defaults: defaults)
    }

    private var defaults: UserDefaults { storage.defaults }

    /// `plugins.<id>.`
    public var prefix: String { "plugins.\(pluginID.rawValue)." }

    /// The full `UserDefaults` key for a plugin-local name.
    public func key(_ name: String) -> String { prefix + name }

    public func bool(_ name: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key(name)) as? Bool ?? fallback
    }

    public func integer(_ name: String, default fallback: Int) -> Int {
        defaults.object(forKey: key(name)) as? Int ?? fallback
    }

    public func string(_ name: String) -> String? {
        defaults.string(forKey: key(name))
    }

    public func stringArray(_ name: String) -> [String]? {
        defaults.stringArray(forKey: key(name))
    }

    public func set(_ value: Bool, for name: String) {
        defaults.set(value, forKey: key(name))
    }

    public func set(_ value: Int, for name: String) {
        defaults.set(value, forKey: key(name))
    }

    public func set(_ value: String, for name: String) {
        defaults.set(value, forKey: key(name))
    }

    public func set(_ value: [String], for name: String) {
        defaults.set(value, forKey: key(name))
    }

    public func removeValue(for name: String) {
        defaults.removeObject(forKey: key(name))
    }
}

/// Carries a `UserDefaults` across isolation domains.
///
/// `@unchecked Sendable` is safe here: Apple documents `UserDefaults` as thread-safe, the reference is
/// immutable (`let`), and this wrapper exposes no other state.
private final class DefaultsStorage: @unchecked Sendable {
    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }
}

/// Everything a plugin receives from the host. Plugins never reach for globals
/// (`NSPasteboard.general`, `NSWorkspace.shared`, the real Keychain) directly.
public struct PluginContext: Sendable {
    /// `Application Support/Pounce/Plugins/<id>/`, created by the host with mode 0700.
    public let storageDirectory: URL
    public let settings: PluginSettings
    /// Ranking signals in `ranking.sqlite`, keys `<id>:<key>`.
    public let usage: any UsageRecorder
    /// `subsystem = app.pounce`, `category = <id>`.
    public let logger: Logger
    public let keychain: any KeychainClient
    public let pasteboard: any PasteboardClient
    public let events: any EventPoster
    public let workspace: any WorkspaceClient
    public let permissions: any PermissionsReader
    public let clock: any Clock<Duration>

    public init(
        storageDirectory: URL,
        settings: PluginSettings,
        usage: any UsageRecorder,
        logger: Logger,
        keychain: any KeychainClient,
        pasteboard: any PasteboardClient,
        events: any EventPoster,
        workspace: any WorkspaceClient,
        permissions: any PermissionsReader,
        clock: any Clock<Duration>
    ) {
        self.storageDirectory = storageDirectory
        self.settings = settings
        self.usage = usage
        self.logger = logger
        self.keychain = keychain
        self.pasteboard = pasteboard
        self.events = events
        self.workspace = workspace
        self.permissions = permissions
        self.clock = clock
    }
}
