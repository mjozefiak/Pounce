import Foundation
import Observation
import PounceKit
import os

/// Lifecycle state of one plugin.
enum PluginState {
    case disabled
    case activating
    case active
    case failed(any Error)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Owns every plugin's lifecycle: creation with its context, `activate()` / `deactivate()`, enabling and
/// disabling, the `failed` state, and running search sources with a per-source time budget.
///
/// Failure isolation: a plugin whose `activate()` throws becomes `failed` and contributes nothing
/// (no sources, commands or panel modes); the others keep working. Lifecycle operations on one plugin
/// run strictly in order, even when callers overlap.
@Observable
final class PluginHost {
    struct Entry {
        let manifest: PluginManifest
        let plugin: any PouncePlugin
        let storageDirectory: URL
        let cachesDirectory: URL
        /// Where the plugin's ranking rows live (`ranking.sqlite`), erased with its data.
        let usage: any UsageRecorder
        fileprivate(set) var state: PluginState
    }

    /// Plugins sorted by `manifest.order`.
    private(set) var entries: [Entry] = []

    @ObservationIgnored private let settings: any SettingsStore
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logger: Logger
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored let sourceBudget: Duration
    @ObservationIgnored private var pending: [PluginID: Task<Void, Never>] = [:]

    /// - Parameters:
    ///   - pluginTypes: usually `PluginRegistry.all`. A duplicate `PluginID` is skipped and logged.
    ///   - makeContext: builds each plugin's context from its manifest.
    ///   - settings: where `plugins.<id>.enabled` lives.
    init(
        pluginTypes: [any PouncePlugin.Type],
        makeContext: (PluginManifest) -> PluginContext,
        settings: any SettingsStore,
        fileManager: FileManager = .default,
        sourceBudget: Duration = .milliseconds(150),
        clock: any Clock<Duration> = ContinuousClock(),
        logger: Logger = Logger(subsystem: "app.pounce", category: "host")
    ) {
        self.settings = settings
        self.fileManager = fileManager
        self.sourceBudget = sourceBudget
        self.clock = clock
        self.logger = logger

        var seen = Set<PluginID>()
        var built: [Entry] = []
        for type in pluginTypes {
            let manifest = type.manifest
            guard seen.insert(manifest.id).inserted else {
                logger.error("Skipping duplicate plugin id \(manifest.id.rawValue, privacy: .public)")
                continue
            }
            let context = makeContext(manifest)
            built.append(
                Entry(
                    manifest: manifest,
                    plugin: type.init(context: context),
                    storageDirectory: context.storageDirectory,
                    cachesDirectory: context.cachesDirectory,
                    usage: context.usage,
                    state: .disabled
                )
            )
        }
        entries = built.sorted { ($0.manifest.order, $0.manifest.id) < ($1.manifest.order, $1.manifest.id) }
    }

    // MARK: Queries

    func state(of id: PluginID) -> PluginState? {
        entries.first { $0.manifest.id == id }?.state
    }

    func isEnabled(_ id: PluginID) -> Bool {
        guard let entry = entries.first(where: { $0.manifest.id == id }) else { return false }
        guard case .bool(let enabled) = settings.value(forKey: SettingsKeys.pluginEnabled(id)) else {
            return entry.manifest.defaultEnabled
        }
        return enabled
    }

    private var activeEntries: [Entry] { entries.filter { $0.state.isActive } }

    /// Commands of active plugins only; disabled or failed plugins register nothing.
    var activeCommands: [PluginCommand] { activeEntries.flatMap { $0.plugin.commands } }

    var activePanelModes: [PanelMode] { activeEntries.flatMap { $0.plugin.panelModes } }

    var activeSources: [RegisteredSource] {
        activeEntries.flatMap { entry in
            entry.plugin.searchSources.map { RegisteredSource(pluginID: entry.manifest.id, source: $0) }
        }
    }

    // MARK: Lifecycle

    /// Activates every enabled plugin, in `manifest.order`.
    func start() async {
        for entry in entries where isEnabled(entry.manifest.id) {
            await enqueue(entry.manifest.id) { host in await host.activateNow(entry.manifest.id) }
        }
    }

    /// Deactivates every plugin, for app termination. The enabled setting is not changed.
    func stop() async {
        for entry in entries {
            await enqueue(entry.manifest.id) { host in await host.deactivateNow(entry.manifest.id) }
        }
    }

    /// Persists the toggle and activates or deactivates the plugin without a restart.
    func setEnabled(_ enabled: Bool, for id: PluginID) async {
        guard entries.contains(where: { $0.manifest.id == id }) else { return }
        settings.setValue(.bool(enabled), forKey: SettingsKeys.pluginEnabled(id))
        await enqueue(id) { host in
            if enabled {
                await host.activateNow(id)
            } else {
                await host.deactivateNow(id)
            }
        }
    }

    /// "Erase Data": deactivates the plugin, lets it erase what it keeps elsewhere, deletes
    /// `Plugins/<id>/`, its caches and its rows in `ranking.sqlite`, and activates it again when it is
    /// enabled.
    func eraseData(for id: PluginID) async throws {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else { return }
        let plugin = entries[index].plugin
        let directories = [entries[index].storageDirectory, entries[index].cachesDirectory]
        let usage = entries[index].usage
        var failure: (any Error)?
        await enqueue(id) { host in
            await host.deactivateNow(id)
            do {
                try await plugin.eraseData()
                for directory in directories where host.fileManager.fileExists(atPath: directory.path) {
                    try host.fileManager.removeItem(at: directory)
                }
                try await usage.removeAll(pluginID: id)
            } catch {
                failure = error
                return
            }
            if host.isEnabled(id) {
                await host.activateNow(id)
            }
        }
        if let failure {
            throw failure
        }
    }

    // MARK: Search

    /// Runs every active source concurrently with the per-source budget.
    func query(_ query: NormalizedQuery, limit: Int) async -> [SourceResult] {
        let results = await SourceRunner.run(
            activeSources,
            query: query,
            limit: limit,
            budget: sourceBudget,
            clock: clock
        )
        for result in results {
            switch result.outcome {
            case .failed(let error):
                logger.error(
                    "Source \(result.sourceID.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)"
                )
            case .timedOut:
                logger.notice("Source \(result.sourceID.rawValue, privacy: .public) exceeded its budget")
            case .results, .cancelled:
                break
            }
        }
        return results
    }

    // MARK: Private

    /// Runs lifecycle operations for one plugin strictly in order.
    private func enqueue(_ id: PluginID, _ operation: @escaping (PluginHost) async -> Void) async {
        let previous = pending[id]
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await operation(self)
        }
        pending[id] = task
        await task.value
    }

    private func setState(_ state: PluginState, for id: PluginID) {
        guard let index = entries.firstIndex(where: { $0.manifest.id == id }) else { return }
        entries[index].state = state
    }

    private func activateNow(_ id: PluginID) async {
        guard let entry = entries.first(where: { $0.manifest.id == id }) else { return }
        if case .active = entry.state { return }
        setState(.activating, for: id)
        do {
            try createStorageDirectory(entry.storageDirectory)
            try await entry.plugin.activate()
            setState(.active, for: id)
            logger.info("Activated plugin \(id.rawValue, privacy: .public)")
        } catch {
            // Release whatever the failed activation started; deactivate() is idempotent.
            await entry.plugin.deactivate()
            setState(.failed(error), for: id)
            logger.error(
                "Plugin \(id.rawValue, privacy: .public) failed to activate: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func deactivateNow(_ id: PluginID) async {
        guard let entry = entries.first(where: { $0.manifest.id == id }) else { return }
        await entry.plugin.deactivate()
        setState(.disabled, for: id)
    }

    private func createStorageDirectory(_ url: URL) throws {
        try AppEnvironment.createPrivateDirectory(url, fileManager: fileManager)
    }
}
