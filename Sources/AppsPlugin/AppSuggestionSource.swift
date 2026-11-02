import Foundation
import PounceKit

/// The suggested apps for the empty panel: the top apps by activity, as `apps:<bundleID>` candidates with
/// the app's icon and a "Running" badge for running apps. Reads only memory (the activity snapshot, the
/// app list) plus one hop to the main actor for the running apps.
struct AppSuggestionSource: SuggestionSource {
    static let hideID = "apps.hideSuggestion"

    let id: SourceID = "apps.suggestions"
    let store: AppStore
    let activity: ActivityStore
    let settings: PluginSettings
    let usage: any UsageRecorder
    let workspace: any WorkspaceClient
    let ownBundleIdentifier: String?
    let resultsChanged: @Sendable () -> Void
    /// Called after "Hide from Suggestions" changed the hidden list, so an open Settings pane catches up.
    let hiddenChanged: @MainActor @Sendable () -> Void
    let now: @Sendable () -> Date

    init(
        store: AppStore,
        activity: ActivityStore,
        settings: PluginSettings,
        usage: any UsageRecorder,
        workspace: any WorkspaceClient,
        ownBundleIdentifier: String?,
        resultsChanged: @escaping @Sendable () -> Void,
        hiddenChanged: @escaping @MainActor @Sendable () -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.activity = activity
        self.settings = settings
        self.usage = usage
        self.workspace = workspace
        self.ownBundleIdentifier = ownBundleIdentifier
        self.resultsChanged = resultsChanged
        self.hiddenChanged = hiddenChanged
        self.now = now
    }

    func suggestions(limit: Int) async throws -> [Candidate] {
        try Task.checkCancellation()
        guard settings.bool(AppsSettingsKey.suggestionsEnabled, default: true) else { return [] }
        let snapshot = activity.snapshot
        guard !snapshot.isReadOnly, !snapshot.apps.isEmpty else { return [] }
        let workspace = workspace
        let running = await MainActor.run { workspace.runningApplicationBundleIDs }
        try Task.checkCancellation()
        let suggestions = SuggestionEngine.suggestions(
            snapshot: snapshot,
            apps: store.apps.map(\.record),
            hidden: Set(HiddenSuggestions.list(settings)),
            running: running,
            ownBundleIdentifier: ownBundleIdentifier,
            now: now(),
            limit: min(limit, SuggestionEngine.limit)
        )
        let runningBadge = String(localized: "Running", comment: "Badge on a suggested app that is running")
        return suggestions.map { suggestion in
            Candidate(
                itemKey: ItemKey(pluginID: AppsPlugin.manifest.id, key: suggestion.record.bundleIdentifier),
                title: suggestion.record.name,
                icon: .file(suggestion.record.url),
                match: MatchResult(tier: .exact, score: 0),
                badge: suggestion.isRunning ? runningBadge : nil
            )
        }
    }

    /// Open, Show in Finder (as for any app result) and Hide from Suggestions (Control-X).
    func actions(for candidate: Candidate) -> [ResultAction] {
        guard let app = store.app(for: candidate.itemKey) else { return [] }
        let actions = AppActions(
            record: app.record, itemKey: app.itemKey, usage: usage, workspace: workspace, clock: now)
        return actions.all + [hide(app.record.bundleIdentifier)]
    }

    private func hide(_ bundleID: String) -> ResultAction {
        let settings = settings
        let resultsChanged = resultsChanged
        let hiddenChanged = hiddenChanged
        return ResultAction(
            id: Self.hideID,
            title: LocalizedStringResource(
                "Hide from Suggestions", comment: "Result action that stops suggesting the selected app"),
            symbolName: "eye.slash",
            shortcut: KeyShortcut(key: "x", modifiers: .control),
            keepsPanelOpen: true
        ) { _ in
            HiddenSuggestions.add(bundleID, to: settings)
            resultsChanged()
            await hiddenChanged()
        }
    }
}
