import Foundation
import LintelKit
import os

@testable import WindowsPlugin

/// In-memory ports and a temporary directory for one test; `tearDown()` removes what it made.
final class WindowsHarness: @unchecked Sendable {
    let directory: URL
    let store = MemorySettings()
    /// The clock of every context this harness makes: time moves only when a test advances it.
    let clock = VirtualClock(autoAdvance: false)
    /// What every context of this harness shares, like the contexts of one app instance.
    let services = PluginServices()

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
        windows: any WindowClient = NoWindowClient(), permissions: any PermissionsReader = NoPermissions(),
        clock: (any Clock<Duration>)? = nil
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
            clock: clock ?? self.clock,
            windows: windows,
            services: services
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

extension EngineConfig {
    /// The Zones configuration, for tests that set it directly.
    var zones: ZonesConfig {
        get { strategyConfigs[.zones]?.as(ZonesConfig.self) ?? ZonesConfig() }
        set { strategyConfigs[.zones] = AnyLayoutConfig(newValue) }
    }
}

/// A `WindowEngine` over the standard strategies (production passes its one registry explicitly).
func makeEngine(
    client: any WindowClient, store: StateStore, clock: any Clock<Duration> = ContinuousClock(),
    workspaceCount: Int = WindowsSettings.defaultWorkspaceCount, config: EngineConfig = EngineConfig(),
    tick: Duration = .milliseconds(30), commandBudget: Duration? = nil, watchdog: Watchdog = Watchdog(),
    reporter: EngineReporter = EngineReporter(), strategies: LayoutRegistry = .standard,
    canMove: @escaping @Sendable () -> Bool = { true }
) -> WindowEngine {
    WindowEngine(
        client: client, store: store, clock: clock, workspaceCount: workspaceCount, config: config, tick: tick,
        commandBudget: commandBudget, watchdog: watchdog, reporter: reporter, strategies: strategies, canMove: canMove)
}

/// The reducer over the standard strategies.
extension EngineReducer {
    static func reduce(_ state: EngineState, _ input: EngineInput) -> (EngineState, [EngineEffect]) {
        reduce(state, input, strategies: .standard)
    }
}

extension JournalOwner {
    /// Takes the journal, waiting for whoever holds it (tests that do not bound the wait).
    func beginEngine() async -> UInt64 {
        while true {
            if let lease = tryBeginEngine() { return lease }
            await waitUntilIdle()
        }
    }
}

extension WindowsPlugin {
    /// The report of one recovery pass; an empty one when the engine owns the journal (tests that expect a pass).
    nonisolated static func restoredReport(context: PluginContext) async -> RecoveryReport {
        if case .ran(let report) = await restoreFromJournal(context: context) { return report }
        return RecoveryReport()
    }
}
