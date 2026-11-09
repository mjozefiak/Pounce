import Foundation
import LintelCore
import LintelKit
import Observation
import os

/// Lifecycle state of one plugin.
/// Why the host itself failed a plugin.
enum PluginHostError: Error, Equatable {
    case activationTimedOut
}

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
        let type: any LintelPlugin.Type
        let context: PluginContext
        let plugin: any LintelPlugin
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
    @ObservationIgnored let recoveryBudget: Duration
    /// How long a plugin's `activate()` may take before the host gives up on it (the plugin is then `failed`), so a
    /// stuck activation cannot hold up that plugin's later lifecycle steps, a quit among them.
    @ObservationIgnored let activationBudget: Duration
    @ObservationIgnored private var recoveries: [PluginID: Task<Void, Never>] = [:]
    /// The `recoverAtLaunch` call of each plugin that has not returned yet, even when its bound passed: a retry
    /// never starts a second copy beside it.
    @ObservationIgnored private var recoveryWork: [PluginID: Task<RecoveryOutcome, Never>] = [:]
    /// What `recoverAtLaunch` answered for each plugin; a plugin that has not answered yet is absent.
    private(set) var recoveryOutcomes: [PluginID: RecoveryOutcome] = [:]

    /// - Parameters:
    ///   - pluginTypes: usually `PluginRegistry.all`. A duplicate `PluginID` is skipped and logged.
    ///   - makeContext: builds each plugin's context from its manifest.
    ///   - settings: where `plugins.<id>.enabled` lives.
    init(
        pluginTypes: [any LintelPlugin.Type],
        makeContext: (PluginManifest) -> PluginContext,
        settings: any SettingsStore,
        fileManager: FileManager = .default,
        sourceBudget: Duration = .milliseconds(150),
        recoveryBudget: Duration = .seconds(5),
        activationBudget: Duration = .seconds(20),
        clock: any Clock<Duration> = ContinuousClock(),
        logger: Logger = Logger(subsystem: "com.lintelapp", category: "host")
    ) {
        self.settings = settings
        self.fileManager = fileManager
        self.sourceBudget = sourceBudget
        self.recoveryBudget = recoveryBudget
        self.activationBudget = activationBudget
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
                    type: type,
                    context: context,
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

    /// A plugin whose manifest says `canBeDisabled == false` is always enabled; a stored `false` (for example
    /// from `defaults write`) is ignored.
    func isEnabled(_ id: PluginID) -> Bool {
        guard let entry = entries.first(where: { $0.manifest.id == id }) else { return false }
        guard entry.manifest.canBeDisabled else { return true }
        guard case .bool(let enabled) = settings.value(forKey: SettingsKeys.pluginEnabled(id)) else {
            return entry.manifest.defaultEnabled
        }
        return enabled
    }

    /// Offers a file the user opened with Lintel to the registered plugins in order until one takes it (the
    /// file types a plugin handles are declared in `Info.plist`). `false` when nobody wanted it.
    func openFile(_ url: URL) async -> Bool {
        for entry in entries where await entry.plugin.handleOpenedFile(url) { return true }
        return false
    }

    /// Offers several opened files in order and stops at the first one a plugin takes: the importer shows one
    /// summary at a time, so a second file would silently replace the first. Returns how many files were left
    /// unopened (never offered, or taken by nobody after the first taken one).
    func openFiles(_ urls: [URL]) async -> Int {
        for (index, url) in urls.enumerated() where url.isFileURL {
            if await openFile(url) { return urls.count - index - 1 }
        }
        return 0
    }

    private var activeEntries: [Entry] { entries.filter { $0.state.isActive } }

    /// Commands of active plugins only; disabled or failed plugins register nothing.
    var activeCommands: [PluginCommand] { activeEntries.flatMap { $0.plugin.commands } }

    var activePanelModes: [PanelMode] { activeEntries.flatMap { $0.plugin.panelModes } }

    /// Status lines of active plugins, in plugin order.
    var activeSearchStatuses: [(pluginID: PluginID, status: SearchStatus)] {
        activeEntries.flatMap { entry in entry.plugin.searchStatus.map { (entry.manifest.id, $0) } }
    }

    var activeSources: [RegisteredSource] {
        activeEntries.flatMap { entry in
            entry.plugin.searchSources.map { RegisteredSource(pluginID: entry.manifest.id, source: $0) }
        }
    }

    /// Suggestion sources of active plugins, in plugin order, each presented as a `SearchSource` so the
    /// runner's budget and the panel's action handling apply unchanged.
    var activeSuggestionSources: [RegisteredSource] {
        activeEntries.flatMap { entry in
            entry.plugin.suggestionSources.map {
                RegisteredSource(pluginID: entry.manifest.id, source: SuggestionSourceAdapter(source: $0))
            }
        }
    }

    // MARK: Lifecycle

    /// Starts `recoverAtLaunch` for every registered plugin (enabled or not) in parallel, then activates every
    /// enabled plugin in `manifest.order`. A plugin's activation waits only for its own recovery, which is
    /// bounded by `recoveryBudget`, so launch is never held up for longer than that. Recoveries of disabled
    /// plugins are not waited for (`waitForRecoveries()` does).
    func start() async {
        beginRecoveries()
        for entry in entries where isEnabled(entry.manifest.id) {
            let id = entry.manifest.id
            await enqueue(id) { host in
                await host.recoveries[id]?.value
                await host.activateNow(id)
            }
        }
    }

    /// Runs `recoverAtLaunch` once per registered plugin type that has not run it yet.
    func beginRecoveries() {
        for entry in entries where recoveries[entry.manifest.id] == nil {
            startRecovery(of: entry)
        }
    }

    /// Runs `recoverAtLaunch` again for every plugin whose last answer was `.deferred` and that is not running
    /// it now: the host calls it on app activation and on a permission change.
    func retryDeferredRecoveries() {
        for entry in entries where recoveryOutcomes[entry.manifest.id] == .deferred {
            startRecovery(of: entry)
        }
    }

    /// Suspends until every recovery that is running has answered or hit its bound.
    func waitForRecoveries() async {
        for task in Array(recoveries.values) {
            await task.value
        }
    }

    private func startRecovery(of entry: Entry) {
        let id = entry.manifest.id
        // A call that is still running (it passed its bound earlier) owns the recovery: no second copy.
        guard recoveryWork[id] == nil else {
            recoveryOutcomes[id] = .deferred
            return
        }
        // A metatype is immutable and `recoverAtLaunch` is nonisolated, so sharing it is safe.
        nonisolated(unsafe) let type = entry.type
        let context = entry.context
        let work = Task { await type.recoverAtLaunch(context: context) }
        recoveryWork[id] = work
        let budget = recoveryBudget
        let clock = clock
        recoveries[id] = Task { [weak self] in
            // When the bound passes first the answer is `.deferred` (the plugin keeps what is left to do) and the
            // work is cancelled; the host does not wait for work that ignores cancellation.
            let answer = await withDeadline(budget, clock: clock) { await work.value }
            if answer == nil { work.cancel() }
            let outcome = answer ?? .deferred
            self?.recoveryOutcomes[id] = outcome
            self?.logger.info(
                "Recovery of \(id.rawValue, privacy: .public): \(outcome == .done ? "done" : "deferred", privacy: .public)"
            )
        }
        // Cleared when the call really returns, which may be long after its bound.
        Task { [weak self] in
            _ = await work.value
            self?.recoveryWork[id] = nil
        }
    }

    /// Deactivates every plugin, for app termination. The enabled setting is not changed.
    func stop() async {
        for entry in entries {
            await enqueue(entry.manifest.id) { host in await host.deactivateNow(entry.manifest.id) }
            // The plugin's shared services go with it (the app is quitting).
            entry.context.services.teardown(pluginID: entry.manifest.id)
        }
    }

    /// Persists the toggle and activates or deactivates the plugin without a restart. Switching off a plugin
    /// that cannot be disabled does nothing.
    func setEnabled(_ enabled: Bool, for id: PluginID) async {
        guard let entry = entries.first(where: { $0.manifest.id == id }) else { return }
        guard enabled || entry.manifest.canBeDisabled else { return }
        settings.setValue(.bool(enabled), forKey: SettingsKeys.pluginEnabled(id))
        await enqueue(id) { host in
            if enabled {
                // A recovery that is still running owns the plugin's journal: activation waits for it, so the
                // plugin's own store never starts from a snapshot the recovery is about to change.
                await host.recoveries[id]?.value
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
            await host.recoveries[id]?.value
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

    /// Runs suggestion sources (by default every active one) concurrently with the per-source budget;
    /// the query is empty.
    func querySuggestions(_ sources: [RegisteredSource]? = nil, limit: Int) async -> [SourceResult] {
        let results = await SourceRunner.run(
            sources ?? activeSuggestionSources,
            query: NormalizedQuery(raw: "", normalized: ""),
            limit: limit,
            budget: sourceBudget,
            clock: clock
        )
        for result in results {
            switch result.outcome {
            case .failed(let error):
                logger.error(
                    "Suggestion source \(result.sourceID.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .private)"
                )
            case .timedOut:
                logger.notice("Suggestion source \(result.sourceID.rawValue, privacy: .public) exceeded its budget")
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
            let plugin = entry.plugin
            let activation = Task { try await plugin.activate() }
            let budget = activationBudget
            let clock = clock
            guard let result = await withDeadline(budget, clock: clock, { await activation.result }) else {
                activation.cancel()
                throw PluginHostError.activationTimedOut
            }
            try result.get()
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
