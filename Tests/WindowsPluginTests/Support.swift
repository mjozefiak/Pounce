import Foundation
import LintelKit
import Testing
import os

@testable import WindowsPlugin

/// The test's own `PluginServices`: one value per plugin and key, like the host's (the contracts target has no
/// shared implementation; the host's lives in `LintelApp`, which plugin tests do not import).
final class TestPluginServices: PluginServices, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: any Sendable] = [:]

    func value<Key: PluginServiceKey>(_ key: Key.Type, pluginID: PluginID, context: PluginContext) -> Key.Value {
        let address = "\(pluginID.rawValue)/\(ObjectIdentifier(key).hashValue)"
        if let existing = lock.withLock({ values[address] }) as? Key.Value { return existing }
        let made = Key.make(context: context)
        return lock.withLock {
            if let existing = values[address] as? Key.Value { return existing }
            values[address] = made
            return made
        }
    }

    func teardown(pluginID: PluginID) {}
}

/// In-memory ports and a temporary directory for one test; `tearDown()` removes what it made.
final class WindowsHarness: @unchecked Sendable {
    let directory: URL
    let store = MemorySettings()
    /// The clock of every context this harness makes: time moves only when a test advances it.
    let clock = VirtualClock(autoAdvance: false)
    /// What every context of this harness shares, like the contexts of one app instance.
    let services = TestPluginServices()

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
    /// Takes the journal, waiting for whoever holds it, at most `limit` of real time: after that an Issue is recorded
    /// (the test fails) and 0 is returned, instead of waiting for ever.
    func acquireLease(limit: Duration = .seconds(30), sourceLocation: SourceLocation = #_sourceLocation) async
        -> UInt64
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while true {
            if let lease = tryBeginEngine() { return lease }
            let remaining = clock.now.duration(to: deadline)
            if remaining > .zero, await waitUntilIdle(within: remaining, clock: clock) { continue }
            Issue.record("the journal was not free within \(limit)", sourceLocation: sourceLocation)
            return 0
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

/// Auto-tile's options spelled out the way most tests think of them (gaps and the first split); the production
/// types only know opaque option values.
extension LayoutConfig {
    init(
        defaultKind: LayoutKind, innerGap: Int, outerGap: Int, rootOrientation: TilingOrientation,
        overrides: [WorkspaceID: WorkspaceOverride] = [:]
    ) {
        self.init(
            defaultKind: defaultKind,
            optionDefaults: [
                .tiling: [
                    TilingStrategy.innerGapID: .int(innerGap), TilingStrategy.outerGapID: .int(outerGap),
                    TilingStrategy.rootOrientationID: .string(rootOrientation.rawValue),
                ]
            ], overrides: overrides)
    }
}

extension WorkspaceOverride {
    init(kind: LayoutKind? = nil, innerGap: Int? = nil, outerGap: Int? = nil, rootOrientation: TilingOrientation? = nil)
    {
        self.init(kind: kind)
        if let innerGap { options[TilingStrategy.innerGapID] = .int(innerGap) }
        if let outerGap { options[TilingStrategy.outerGapID] = .int(outerGap) }
        if let rootOrientation { options[TilingStrategy.rootOrientationID] = .string(rootOrientation.rawValue) }
    }

    var innerGap: Int? { if case .int(let value)? = options[TilingStrategy.innerGapID] { value } else { nil } }
    var outerGap: Int? { if case .int(let value)? = options[TilingStrategy.outerGapID] { value } else { nil } }
    var rootOrientation: TilingOrientation? {
        if case .string(let value)? = options[TilingStrategy.rootOrientationID] {
            TilingOrientation(rawValue: value)
        } else {
            nil
        }
    }
}

extension ResolvedLayout {
    var gaps: TilingGaps { tilingGaps }
    var rootOrientation: TilingOrientation { tilingOrientation }
}

/// Auto-tile's two global gaps through the generic option API.
extension WindowsSettings {
    private var gapOptions: (inner: LayoutOption, outer: LayoutOption) {
        let options = TilingStrategy().options
        return (options[0], options[1])
    }

    var innerGap: Int {
        if case .int(let value) = globalValue(of: gapOptions.inner) { value } else { 0 }
    }

    var outerGap: Int {
        if case .int(let value) = globalValue(of: gapOptions.outer) { value } else { 0 }
    }

    func setInnerGap(_ points: Int) { setGlobalValue(.int(points), of: gapOptions.inner) }
    func setOuterGap(_ points: Int) { setGlobalValue(.int(points), of: gapOptions.outer) }
}
