import Foundation
import PounceKit
import SwiftUI
import os

/// App search: the first plugin (spec Phase 1).
///
/// The app list comes from a directory scan of the index roots (the source of truth), supplemented by a
/// live Spotlight query, deduplicated by bundle identifier with `/Applications` preferred. The last list
/// is cached in `apps.json`, so results are available before the first scan finishes. The list is
/// refreshed at activation, when Spotlight reports a change and when the system language changes.
///
/// Settings (`plugins.apps.*`):
/// - `roots` (`[String]`, or one path as a `String`): index roots in priority order, replacing the
///   defaults. QA runs point it at a fixture directory.
/// - `spotlight` (`Bool`, default `true`): whether the Spotlight query supplements the scan.
@MainActor
public final class AppsPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "apps",
        displayName: LocalizedStringResource("Applications", comment: "Results section and plugin name for apps"),
        symbolName: "square.grid.2x2",
        order: 10
    )

    /// Spotlight updates arrive in bursts; one rescan follows each quiet period of this length.
    static let refreshDelay: Duration = .seconds(2)

    private let context: PluginContext
    let store = AppStore()
    private var watcher: AppMetadataWatcher?
    private var watcherTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var pendingRefresh: Task<Void, Never>?
    private var localeObserver: (any NSObjectProtocol)?
    private var spotlightPaths: [String] = []
    /// `Plugins/apps/activity.json`: app activity behind suggestions.
    let activity: ActivityStore
    private var settingsModel: AppsSettingsModel?
    private var isActive = false

    public init(context: PluginContext) {
        self.context = context
        self.activity = ActivityStore(
            directory: context.storageDirectory, clock: context.clock, logger: context.logger)
    }

    public var searchSources: [any SearchSource] {
        [AppSearchSource(store: store, usage: context.usage, workspace: context.workspace)]
    }

    public var suggestionSources: [any SuggestionSource] {
        [
            AppSuggestionSource(
                store: store,
                activity: activity,
                settings: context.settings,
                usage: context.usage,
                workspace: context.workspace,
                ownBundleIdentifier: ownBundleIdentifier,
                resultsChanged: context.resultsChanged
            )
        ]
    }

    /// Pounce's own bundle identifier, never tracked or suggested.
    var ownBundleIdentifier: String? { Bundle.main.bundleIdentifier }

    public func activate() async throws {
        await activity.load()
        isActive = true
        if let cached = cache.load() {
            store.publish(cached)
            context.resultsChanged()
        }
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        if context.settings.bool(AppsSettingsKey.spotlight, default: true) {
            startSpotlight()
        }
        refresh()
    }

    public func deactivate() async {
        isActive = false
        watcherTask?.cancel()
        watcherTask = nil
        watcher?.stop()
        watcher = nil
        pendingRefresh?.cancel()
        pendingRefresh = nil
        refreshTask?.cancel()
        refreshTask = nil
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
        localeObserver = nil
        spotlightPaths = []
        await activity.close()
    }

    public func settingsPane() -> AnyView? {
        AnyView(AppsSettingsPane(model: makeSettingsModel()))
    }

    func makeSettingsModel() -> AppsSettingsModel {
        if let settingsModel {
            settingsModel.reload()
            return settingsModel
        }
        let model = AppsSettingsModel(settings: context.settings, store: activity)
        model.roots = { [weak self] in self?.roots ?? [] }
        model.appName = { [weak self] bundleID in
            self?.store.app(for: ItemKey(pluginID: Self.manifest.id, key: bundleID))?.record.name
        }
        model.spotlightChanged = { [weak self] enabled in self?.setSpotlight(enabled) }
        let resultsChanged = context.resultsChanged
        model.resultsChanged = { resultsChanged() }
        settingsModel = model
        return model
    }

    /// The Spotlight toggle: starts or stops the supplement and rescans.
    private func setSpotlight(_ enabled: Bool) {
        guard isActive else { return }
        watcherTask?.cancel()
        watcherTask = nil
        watcher?.stop()
        watcher = nil
        spotlightPaths = []
        if enabled {
            startSpotlight()
        }
        refresh()
    }

    /// Waits for the scan that is running, if any (tests).
    func waitForRefresh() async {
        await refreshTask?.value
    }

    // MARK: Index

    var roots: [URL] {
        let settings = context.settings
        let paths = settings.stringArray(AppsSettingsKey.roots) ?? settings.string(AppsSettingsKey.roots).map { [$0] }
        guard let paths, !paths.isEmpty else {
            return AppScanner.defaultRoots(home: FileManager.default.homeDirectoryForCurrentUser)
        }
        return paths.map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    private var cache: AppCache {
        AppCache(directory: context.cachesDirectory)
    }

    /// Rescans in the background and publishes the result; a newer refresh cancels an older one.
    func refresh() {
        refreshTask?.cancel()
        let scanner = AppScanner(roots: roots)
        let extraPaths = spotlightPaths
        let store = store
        let cache = cache
        let logger = context.logger
        let resultsChanged = context.resultsChanged
        refreshTask = Task.detached(priority: .utility) {
            do {
                var records = try scanner.scan()
                let scanned = Set(records.map(\.path))
                for path in extraPaths where !scanned.contains(path) {
                    try Task.checkCancellation()
                    if let record = scanner.record(at: URL(filePath: path, directoryHint: .isDirectory)) {
                        records.append(record)
                    }
                }
                try Task.checkCancellation()
                let apps = AppCatalog.deduplicate(records)
                store.publish(apps)
                resultsChanged()
                try cache.save(apps)
                logger.info("Indexed \(apps.count, privacy: .public) apps")
            } catch is CancellationError {
                return
            } catch {
                logger.error("App index refresh failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func startSpotlight() {
        let watcher = AppMetadataWatcher()
        self.watcher = watcher
        let stream = watcher.start()
        watcherTask = Task { [weak self] in
            for await paths in stream {
                self?.spotlightChanged(paths.filter(AppPathFilter.isEligible))
            }
        }
    }

    private func spotlightChanged(_ paths: [String]) {
        guard paths != spotlightPaths else { return }
        spotlightPaths = paths
        pendingRefresh?.cancel()
        let clock = context.clock
        pendingRefresh = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.refreshDelay)
            } catch {
                return
            }
            self?.refresh()
        }
    }
}
