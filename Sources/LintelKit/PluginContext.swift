import Foundation
import SwiftUI
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

/// A hold on the Escape key, returned by `PluginContext.claimEscapeKey`. While `isActive`, the host
/// registers a global Escape shortcut that swallows the key and calls the plugin's handler; `release()`
/// gives the key back. Added with dictation.
public struct EscapeKeyClaim: Sendable {
    /// Whether Escape is really claimed. False for the empty claim, a second claim while one is held, and a
    /// registration another app blocked, so the UI shows "✕ cancels" instead of "Esc cancels".
    public let isActive: Bool
    private let onRelease: @MainActor @Sendable () -> Void

    public init(isActive: Bool, release: @escaping @MainActor @Sendable () -> Void = {}) {
        self.isActive = isActive
        self.onRelease = release
    }

    /// A claim that holds nothing.
    public static let inactive = EscapeKeyClaim(isActive: false)

    /// Gives Escape back. Safe to call more than once.
    @MainActor public func release() {
        onRelease()
    }
}

/// Everything a plugin receives from the host. Plugins never reach for globals
/// (`NSPasteboard.general`, `NSWorkspace.shared`, the real Keychain) directly.
public struct PluginContext: Sendable {
    /// `Application Support/Lintel/Plugins/<id>/`, created by the host with mode 0700.
    public let storageDirectory: URL
    public let settings: PluginSettings
    /// Ranking signals in `ranking.sqlite`, keys `<id>:<key>`.
    public let usage: any UsageRecorder
    /// `subsystem = com.lintelapp`, `category = <id>`.
    public let logger: Logger
    public let keychain: any KeychainClient
    public let pasteboard: any PasteboardClient
    public let events: any EventPoster
    public let workspace: any WorkspaceClient
    public let permissions: any PermissionsReader
    public let clock: any Clock<Duration>
    /// Rebuildable caches (`~/Library/Caches/Lintel/Plugins/<id>/`), created lazily by the plugin.
    /// Defaults to `Caches/` inside the storage directory. Added in Phase 1.
    public let cachesDirectory: URL
    /// Tells the host that the plugin's results changed (its index finished loading, a new item arrived),
    /// so an open panel searches again. Callable from any thread; the host coalesces calls. Added in
    /// Phase 1; defaults to doing nothing.
    public let resultsChanged: @Sendable () -> Void
    /// Builds the shell's shortcut recorder for one of this plugin's commands (by `PluginCommand.id`), so
    /// a settings pane can let the user change the command's global shortcut. Added in Phase 2; the
    /// default shows nothing.
    public let makeShortcutRecorder: @MainActor @Sendable (_ commandID: String) -> AnyView
    /// Claims the Escape key for a short session (dictation). Only one claim exists at a time; a second one
    /// returns an inactive claim. Added with dictation; the default claims nothing.
    public let claimEscapeKey:
        @MainActor @Sendable (_ onEscape: @escaping @MainActor @Sendable () -> Void) -> EscapeKeyClaim
    /// Opens this plugin's own pane in Settings, for example from a message that points the user there.
    /// Added with dictation; the default does nothing.
    public let openSettings: @MainActor @Sendable () -> Void
    /// `Application Support/Lintel/Models/`, created by the host with mode 0700: downloaded speech and language
    /// models (`speech/`, `llm/`), shared by every plugin that needs one and not removed by Erase Data. Added
    /// with the meeting notes spec; defaults to `Models/` inside the storage directory.
    public let modelsDirectory: URL
    /// The commands of the active plugins for a command palette: commands with `onKeyEvent` are left out, and a
    /// `panelMode` command opens the launcher panel in that mode. Added with the main window; defaults to none.
    public let availableCommands: @MainActor @Sendable () -> [CommandInfo]
    /// Opens the Models pane of Settings, scrolled to the package's row when it is given. Added with the main
    /// window; the default does nothing.
    public let openModels: @MainActor @Sendable (_ packageID: String?) -> Void
    /// Reads and moves other applications' windows (Accessibility). The default
    /// client reports no windows and no displays and is `unsupported`.
    public let windows: any WindowClient
    /// Sets (or, with `nil`, clears) the global shortcut of one of this plugin's commands, as if the user had
    /// recorded it, so a pane can offer one row per family of numbered commands. The default does nothing.
    public let setCommandShortcut: @MainActor @Sendable (_ commandID: String, _ shortcut: KeyShortcut?) -> Void
    /// The shortcut a command has right now (the user's, or its default); `nil` when none. Added with window
    /// management; the default answers `nil`.
    public let commandShortcut: @MainActor @Sendable (_ commandID: String) -> KeyShortcut?

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
        clock: any Clock<Duration>,
        cachesDirectory: URL? = nil,
        resultsChanged: @escaping @Sendable () -> Void = {},
        makeShortcutRecorder: @escaping @MainActor @Sendable (_ commandID: String) -> AnyView = { _ in
            AnyView(EmptyView())
        },
        claimEscapeKey:
            @escaping @MainActor @Sendable (_ onEscape: @escaping @MainActor @Sendable () -> Void) ->
            EscapeKeyClaim = { _ in .inactive },
        openSettings: @escaping @MainActor @Sendable () -> Void = {},
        modelsDirectory: URL? = nil,
        availableCommands: @escaping @MainActor @Sendable () -> [CommandInfo] = { [] },
        openModels: @escaping @MainActor @Sendable (_ packageID: String?) -> Void = { _ in },
        windows: any WindowClient = NoWindowClient(),
        setCommandShortcut: @escaping @MainActor @Sendable (_ commandID: String, _ shortcut: KeyShortcut?) -> Void = {
            _, _ in
        },
        commandShortcut: @escaping @MainActor @Sendable (_ commandID: String) -> KeyShortcut? = { _ in nil }
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
        self.cachesDirectory =
            cachesDirectory ?? storageDirectory.appending(path: "Caches", directoryHint: .isDirectory)
        self.resultsChanged = resultsChanged
        self.makeShortcutRecorder = makeShortcutRecorder
        self.claimEscapeKey = claimEscapeKey
        self.openSettings = openSettings
        self.modelsDirectory =
            modelsDirectory ?? storageDirectory.appending(path: "Models", directoryHint: .isDirectory)
        self.availableCommands = availableCommands
        self.openModels = openModels
        self.windows = windows
        self.setCommandShortcut = setCommandShortcut
        self.commandShortcut = commandShortcut
    }
}
