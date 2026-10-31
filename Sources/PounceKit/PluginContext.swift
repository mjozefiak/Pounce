import Foundation
import os

/// A plugin's settings: keys under the `plugins.<id>.` prefix in the host's `SettingsStore`
/// (`UserDefaults` in the app).
public struct PluginSettings: Sendable {
    public let pluginID: PluginID
    private let store: any SettingsStore

    public init(pluginID: PluginID, store: any SettingsStore) {
        self.pluginID = pluginID
        self.store = store
    }

    /// `plugins.<id>.`
    public var prefix: String { "plugins.\(pluginID.rawValue)." }

    /// The full settings key for a plugin-local name.
    public func key(_ name: String) -> String { prefix + name }

    public func bool(_ name: String, default fallback: Bool) -> Bool {
        guard case .bool(let value) = store.value(forKey: key(name)) else { return fallback }
        return value
    }

    public func integer(_ name: String, default fallback: Int) -> Int {
        guard case .integer(let value) = store.value(forKey: key(name)) else { return fallback }
        return value
    }

    public func string(_ name: String) -> String? {
        guard case .string(let value) = store.value(forKey: key(name)) else { return nil }
        return value
    }

    public func stringArray(_ name: String) -> [String]? {
        guard case .stringArray(let value) = store.value(forKey: key(name)) else { return nil }
        return value
    }

    public func set(_ value: Bool, for name: String) {
        store.setValue(.bool(value), forKey: key(name))
    }

    public func set(_ value: Int, for name: String) {
        store.setValue(.integer(value), forKey: key(name))
    }

    public func set(_ value: String, for name: String) {
        store.setValue(.string(value), forKey: key(name))
    }

    public func set(_ value: [String], for name: String) {
        store.setValue(.stringArray(value), forKey: key(name))
    }

    public func removeValue(for name: String) {
        store.setValue(nil, forKey: key(name))
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
