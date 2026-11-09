import Foundation
import LintelKit
import os

@testable import WindowsPlugin

/// In-memory ports and a temporary directory for one test; `tearDown()` removes what it made.
final class WindowsHarness: @unchecked Sendable {
    let directory: URL
    let store = MemorySettings()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "lintel-windows-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The product default is Auto-tile; most tests are about workspaces and parking, so windows stay where
        // they are unless a test asks for tiling.
        WindowsSettings(pluginSettings).setDefaultKind(.free)
    }

    /// Settings that nothing was ever written to: the product defaults.
    static func freshSettings() -> PluginSettings { PluginSettings(pluginID: "windows", store: MemorySettings()) }

    var pluginSettings: PluginSettings { PluginSettings(pluginID: "windows", store: store) }

    func context(
        windows: any WindowClient = NoWindowClient(), permissions: any PermissionsReader = NoPermissions()
    ) -> PluginContext {
        PluginContext(
            storageDirectory: directory,
            settings: pluginSettings,
            usage: NoUsage(),
            logger: Logger(subsystem: "com.lintelapp.tests", category: "windows"),
            keychain: NoKeychain(),
            pasteboard: NoPasteboard(),
            events: NoEvents(),
            workspace: NoWorkspace(),
            permissions: permissions,
            clock: ContinuousClock(),
            windows: windows
        )
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

final class MemorySettings: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: SettingValue] = [:]

    func value(forKey key: String) -> SettingValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func setValue(_ value: SettingValue?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    var keys: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(values.keys)
    }
}

struct NoKeychain: KeychainClient {
    func readGenericPassword(service: String, account: String) throws(KeychainError) -> Data { throw .itemNotFound }
    func addGenericPassword(_ data: Data, service: String, account: String) throws(KeychainError) {}
    func deleteGenericPassword(service: String, account: String) throws(KeychainError) {}
}

struct NoPasteboard: PasteboardClient {
    @MainActor var changeCount: Int { 0 }
    @MainActor func string() -> String? { nil }
    @MainActor func setString(_ string: String) -> Int { 0 }
}

struct NoEvents: EventPoster {
    @MainActor func postPaste() throws(EventPosterError) { throw .notPermitted }
}

struct NoWorkspace: WorkspaceClient {
    @MainActor var frontmostApplicationPID: pid_t? { nil }
    @MainActor func open(_ url: URL) async throws {}
    @MainActor func revealInFinder(_ urls: [URL]) {}
}

struct NoUsage: UsageRecorder {
    func recordUse(of key: ItemKey, queryPrefix: String?, at date: Date) async throws {}
    func stats(for keys: [ItemKey], queryPrefix: String?) async throws -> [ItemKey: UsageStats] { [:] }
}

struct NoPermissions: PermissionsReader {
    @MainActor func status(of permission: Permission) -> PermissionStatus { .notDetermined }
}

/// A permission reader the test flips by hand.
final class ScriptedPermissions: PermissionsReader, @unchecked Sendable {
    private let lock = NSLock()
    private var granted: Bool

    init(granted: Bool) { self.granted = granted }

    func set(_ granted: Bool) { lock.withLock { self.granted = granted } }

    @MainActor func status(of permission: Permission) -> PermissionStatus {
        lock.withLock { granted } ? .granted : .denied
    }
}

/// Records what the HUD was asked to show.
@MainActor
final class RecordingHUD: WindowsHUDPresenting {
    private(set) var shown: [WindowsHUDState] = []
    var allowAccessibility: @MainActor () -> Void = {}
    func show(_ state: WindowsHUDState) { shown.append(state) }
}

// Typed views of the layout states, for tests that look at one kind. They go through the registry, like the
// engine does, so they also exercise what is stored.

extension EngineState {
    var tiling: [WorkspaceID: TilingTree] { layouts.compactMapValues { $0["tiling"]?.as(TilingTree.self) } }

    var zones: [WorkspaceID: [String: ZoneState]] {
        layouts.compactMapValues { $0["zones"]?.as(ZonesLayoutState.self)?.byDisplay }
    }

    var lastZone: [String: Int] { placementHints }
}

extension WindowsState {
    init(
        order: [WorkspaceID: [WindowID]] = [:], hidden: [HiddenEntry] = [],
        tiling: [WorkspaceID: TilingTree] = [:], zones: [WorkspaceID: [String: ZoneState]] = [:]
    ) {
        var states: [WorkspaceID: [String: AnyLayoutState]] = [:]
        for (workspace, tree) in tiling { states[workspace, default: [:]]["tiling"] = AnyLayoutState(tree) }
        for (workspace, placed) in zones {
            states[workspace, default: [:]]["zones"] = AnyLayoutState(ZonesLayoutState(byDisplay: placed))
        }
        self.init(order: order, hidden: hidden, layouts: LayoutRegistry.standard.encode(states))
    }

    var tiling: [WorkspaceID: TilingTree] {
        LayoutRegistry.standard.decode(layouts).compactMapValues { $0["tiling"]?.as(TilingTree.self) }
    }

    var zones: [WorkspaceID: [String: ZoneState]] {
        LayoutRegistry.standard.decode(layouts).compactMapValues { $0["zones"]?.as(ZonesLayoutState.self)?.byDisplay }
    }
}

extension StateStore {
    func setTiling(_ tiling: [WorkspaceID: TilingTree]) {
        setLayouts(WindowsState(tiling: tiling).layouts)
    }

    func setZones(_ zones: [WorkspaceID: [String: ZoneState]]) {
        setLayouts(WindowsState(zones: zones).layouts)
    }
}
