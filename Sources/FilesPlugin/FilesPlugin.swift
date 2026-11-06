import Foundation
import LintelKit
import LintelUI
import Observation
import SwiftUI
import Synchronization
import os

/// What the views show about the index and access.
@MainActor @Observable
final class FilesState {
    var status = IndexStatus.waiting
    var fullDiskAccess = PermissionStatus.notDetermined
    var plan: IndexPlan?
}

/// File search (spec Phase 3): filenames under the home folder and `/Applications` from Lintel's own
/// index, kept fresh with FSEvents and saved as `Plugins/files/index.snapshot`.
///
/// - The first scan waits for the Full Disk Access onboarding step (or "Start Indexing" in Settings).
///   Without Full Disk Access, Desktop, Documents, Downloads and iCloud Drive are skipped unless the user
///   adds them one at a time, so indexing never shows a series of privacy prompts.
/// - `FileIndex` owns the index; `IndexController` loads, scans, follows FSEvents and saves; the search
///   source reads published snapshots and never waits for a scan.
/// - Uses are recorded in `ranking.sqlite` under `files:<path>`.
///
/// Settings: see `FilesSettings.Key`.
@MainActor
public final class FilesPlugin: LintelPlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "files",
        displayName: LocalizedStringResource("Files", comment: "Results section and plugin name for files"),
        symbolName: "doc",
        order: 20,
        settingsGroup: .search,
        summary: LocalizedStringResource("Find files by name.", comment: "Settings → Features: what Files does")
    )

    static let onboardingStepID = "files.fullDiskAccess"
    /// System Settings → Privacy & Security → Full Disk Access.
    static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    /// How often a search may re-read the Full Disk Access state.
    static let accessRecheckInterval: Duration = .seconds(5)

    let context: PluginContext
    let settings: FilesSettings
    let state = FilesState()
    let index = FileIndex()
    /// The Full Disk Access state and the hidden-items setting, readable off the main actor by path mode.
    let access = AccessFlags()
    private(set) lazy var lister = DirectoryLister(home: settings.home)
    private(set) var controller: IndexController?
    private var runTask: Task<Void, Never>?
    private var isActive = false
    private var lastAccessCheck: ContinuousClock.Instant?
    /// Where app activations are posted (tests use their own centre).
    var appActivationCenter: NotificationCenter = .default
    private var activationObserver: AppActivationObserver?

    public init(context: PluginContext) {
        self.context = context
        self.settings = FilesSettings(context.settings)
        access.includesHidden = settings.includesHidden
        settings.onChange = { [weak self] in self?.settingsChanged() }
    }

    // MARK: Lifecycle

    public func activate() async throws {
        isActive = true
        refreshAccess()
        startIfReady()
        // Coming back from System Settings: a Full Disk Access grant replans the index and updates the banner.
        activationObserver = AppActivationObserver(center: appActivationCenter) { [weak self] in
            self?.refreshAccess()
        }
    }

    public func deactivate() async {
        isActive = false
        activationObserver?.stop()
        activationObserver = nil
        let task = runTask
        runTask = nil
        controller = nil
        task?.cancel()
        await task?.value
        state.status = .waiting
    }

    /// "Erase Data": the host deactivated the plugin and deletes `Plugins/files/` and the plugin's ranking
    /// rows afterwards; the index in memory goes now.
    public func eraseData() async throws {
        await index.replace(with: NameStore())
        context.resultsChanged()
    }

    // MARK: Contributions

    public var searchSources: [any SearchSource] {
        let access = access
        return [
            FileSearchSource(
                index: index, usage: context.usage, workspace: context.workspace, pasteboard: context.pasteboard,
                home: settings.home),
            PathSearchSource(
                lister: lister, usage: context.usage, workspace: context.workspace, pasteboard: context.pasteboard,
                home: settings.home, fullDiskAccess: { access.fullDiskAccess },
                includesHidden: { access.includesHidden }),
        ]
    }

    public var onboardingSteps: [OnboardingStep] {
        let model = viewModel
        return [
            OnboardingStep(
                id: Self.onboardingStepID,
                title: LocalizedStringResource("File Search", comment: "Onboarding step title for file search"),
                symbolName: "doc.text.magnifyingglass",
                text: FilesOnboardingView.text
            ) {
                AnyView(FilesOnboardingView(model: model))
            }
        ]
    }

    public var requiredPermissions: Set<Permission> { [.fullDiskAccess] }

    public func settingsPane() -> AnyView? {
        AnyView(FilesSettingsPane(model: viewModel))
    }

    /// The main window's banner (prototype `set-files`), read by the shell only while active and while the view
    /// draws, so it only reads: Full Disk Access is re-checked when the pane appears and when Lintel becomes the
    /// active app (`refreshAccess()`), which signals `resultsChanged` so the shell reads the banner again.
    public var settingsStatus: SettingsStatus? {
        Self.settingsStatus(
            status: state.status,
            setupCompleted: settings.setupCompleted,
            fullDiskAccess: state.fullDiskAccess,
            startIndexing: { [weak self] in self?.completeSetup() }
        )
    }

    /// The banner id of "Start Indexing".
    nonisolated static let startIndexingActionID = "startIndexing"

    /// "Indexing hasn't started" with Start Indexing and Allow Full Disk Access before the first scan, progress
    /// while the index loads or scans, "Ready · N items indexed." after. Indexing without Full Disk Access is
    /// intended (protected folders are skipped), so the banner acknowledges it and offers it itself.
    nonisolated static func settingsStatus(
        status: IndexStatus,
        setupCompleted: Bool,
        fullDiskAccess: PermissionStatus,
        startIndexing: @escaping @MainActor @Sendable () async -> Void
    ) -> SettingsStatus {
        let hasAccess = fullDiskAccess == .granted
        let allowAccess = SettingsStatusAction(
            title: LocalizedStringResource(
                "Allow Full Disk Access", comment: "Settings → Files banner button: opens the Full Disk Access settings"
            ),
            destination: .systemSettings(.fullDiskAccess))
        let accessFix = hasAccess ? [] : [allowAccess]
        let acknowledged: Set<Permission> = hasAccess ? [] : [.fullDiskAccess]
        guard setupCompleted else {
            let start = SettingsStatusAction(
                title: LocalizedStringResource(
                    "Start Indexing (banner)", defaultValue: "Start Indexing",
                    comment: "Settings → Files banner button: starts the first file scan"),
                destination: .plugin(id: startIndexingActionID, perform: startIndexing))
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "Indexing hasn’t started", comment: "Settings → Files banner before the first file scan"),
                detail: hasAccess
                    ? LocalizedStringResource(
                        "Start indexing to find files by name.",
                        comment: "Settings → Files banner detail before the first scan, with Full Disk Access")
                    : LocalizedStringResource(
                        "Full Disk Access adds Documents and Desktop.",
                        comment: "Settings → Files banner detail: what Full Disk Access adds to the index"),
                fix: [start] + accessFix,
                acknowledgedPermissions: acknowledged)
        }
        switch status.phase {
        case .waiting, .loading:
            return SettingsStatus(
                level: .neutral,
                title: LocalizedStringResource(
                    "Loading the file index…", comment: "Panel progress while the saved index loads"),
                acknowledgedPermissions: acknowledged)
        case .scanning:
            return SettingsStatus(
                level: .neutral,
                title: LocalizedStringResource("Indexing…", comment: "Settings → Files banner while files are indexed"),
                detail: LocalizedStringResource(
                    "\(status.count) items so far.",
                    comment: "Settings → Files banner detail while indexing: the number of items so far"),
                fix: accessFix,
                acknowledgedPermissions: acknowledged)
        case .ready:
            return SettingsStatus(
                level: .ok,
                title: LocalizedStringResource("Ready", comment: "Settings banner level, spoken"),
                detail: hasAccess
                    ? LocalizedStringResource(
                        "\(status.count) items indexed.",
                        comment: "Settings → Files banner detail: the number of indexed files and folders")
                    : LocalizedStringResource(
                        "\(status.count) items indexed. Full Disk Access adds Documents and Desktop.",
                        comment: "Settings → Files banner detail without Full Disk Access: the number of items"),
                fix: accessFix,
                acknowledgedPermissions: acknowledged)
        }
    }

    /// Indexing progress, a "not set up yet" notice before the first scan, and the "no Full Disk Access"
    /// notice. Reading it may re-check Full Disk Access (at most every few seconds), so granting it in
    /// System Settings is noticed the next time the panel searches.
    public var searchStatus: [SearchStatus] {
        refreshAccessIfStale()
        return Self.statuses(
            status: state.status,
            setupCompleted: settings.setupCompleted,
            fullDiskAccess: state.fullDiskAccess,
            noticeDismissed: settings.accessNoticeDismissed,
            openAccessSettings: { [weak self] in self?.openAccessSettings() },
            dismissNotice: { [weak self] in self?.settings.dismissAccessNotice() }
        )
    }

    static func statuses(
        status: IndexStatus,
        setupCompleted: Bool,
        fullDiskAccess: PermissionStatus,
        noticeDismissed: Bool,
        openAccessSettings: @escaping @MainActor @Sendable () -> Void,
        dismissNotice: @escaping @MainActor @Sendable () -> Void
    ) -> [SearchStatus] {
        var result: [SearchStatus] = []
        if !setupCompleted {
            result.append(
                SearchStatus(
                    id: "files.setup",
                    symbolName: "doc.text.magnifyingglass",
                    message: LocalizedStringResource(
                        "File search starts once you choose how Lintel may read your files.",
                        comment: "Panel notice before file indexing was set up"),
                    actions: [
                        SearchStatusAction(
                            id: "files.setup.open",
                            title: LocalizedStringResource(
                                "Set Up…", comment: "Panel button that opens file search settings"),
                            kind: .openSettings)
                    ]
                ))
            return result
        }
        if status.phase == .scanning || status.phase == .loading {
            result.append(
                SearchStatus(
                    id: "files.progress",
                    symbolName: "doc.text.magnifyingglass",
                    message: status.phase == .loading
                        ? LocalizedStringResource(
                            "Loading the file index…", comment: "Panel progress while the saved index loads")
                        : LocalizedStringResource(
                            "Indexing files… \(status.count.formatted())",
                            comment: "Panel progress while files are indexed; the number of items so far"),
                    style: .progress
                ))
        }
        if fullDiskAccess != .granted, !noticeDismissed {
            result.append(
                SearchStatus(
                    id: "files.access",
                    symbolName: "hand.raised",
                    message: LocalizedStringResource(
                        "Without Full Disk Access, Desktop, Documents and Downloads are not searched.",
                        comment: "Panel notice when Full Disk Access is missing"),
                    actions: [
                        SearchStatusAction(
                            id: "files.access.open",
                            title: LocalizedStringResource(
                                "Allow…", comment: "Panel button that opens the Full Disk Access settings"),
                            kind: .run(openAccessSettings)),
                        SearchStatusAction(
                            id: "files.access.dismiss",
                            title: LocalizedStringResource("Dismiss", comment: "Panel button that hides a notice"),
                            kind: .run(dismissNotice)),
                    ]
                ))
        }
        return result
    }

    // MARK: Index

    /// Starts (or restarts, when the plan changed) the index once setup is done.
    func startIfReady() {
        guard isActive, settings.setupCompleted else {
            state.status = .waiting
            return
        }
        let plan = settings.plan(fullDiskAccess: state.fullDiskAccess == .granted)
        if plan == state.plan, runTask != nil { return }
        restart(plan)
    }

    /// Replaces the running index task. The new task waits for the previous one to end (it saves on the way
    /// out), then deletes the snapshot when `deletingSnapshot` (Rebuild Index) and runs. It is always the
    /// tracked `runTask`, so `deactivate()` and the next restart cancel and wait for it.
    private func restart(_ plan: IndexPlan, deletingSnapshot: Bool = false) {
        state.plan = plan
        let previous = runTask
        previous?.cancel()
        let directory = context.storageDirectory
        let controller = IndexController(
            index: index,
            configuration: IndexController.Configuration(plan: plan, storageDirectory: context.storageDirectory),
            logger: context.logger,
            onStatus: { [weak self] status in
                Task { @MainActor in self?.statusChanged(status) }
            },
            onChange: context.resultsChanged
        )
        self.controller = controller
        runTask = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            if deletingSnapshot {
                IndexSnapshot.delete(in: directory)
            }
            await controller.run()
        }
    }

    private func statusChanged(_ status: IndexStatus) {
        guard isActive, state.status != status else { return }
        let phaseChanged = state.status.phase != status.phase
        state.status = status
        if phaseChanged {
            context.resultsChanged()
        }
    }

    /// "Rebuild Index": deletes the snapshot and scans again.
    func rebuild() {
        guard isActive, settings.setupCompleted else { return }
        restart(settings.plan(fullDiskAccess: state.fullDiskAccess == .granted), deletingSnapshot: true)
    }

    /// The Full Disk Access step was finished or skipped, or "Start Indexing" was pressed.
    func completeSetup() {
        refreshAccess()
        settings.completeSetup()
    }

    private func settingsChanged() {
        access.includesHidden = settings.includesHidden
        startIfReady()
        context.resultsChanged()
    }

    // MARK: Access

    /// Re-reads Full Disk Access; when it changed, replans and tells the shell (the banner and the panel
    /// notices follow it).
    func refreshAccess() {
        lastAccessCheck = .now
        let status = context.permissions.status(of: .fullDiskAccess)
        access.fullDiskAccess = status == .granted
        guard status != state.fullDiskAccess else { return }
        state.fullDiskAccess = status
        startIfReady()
        context.resultsChanged()
    }

    private func refreshAccessIfStale() {
        if let lastAccessCheck, ContinuousClock.now - lastAccessCheck < Self.accessRecheckInterval { return }
        refreshAccess()
    }

    func openAccessSettings() {
        guard let url = Self.fullDiskAccessSettings else { return }
        let workspace = context.workspace
        Task { try? await workspace.open(url) }
    }

    var viewModel: FilesViewModel {
        FilesViewModel(
            state: state,
            settings: settings,
            openAccessSettings: { [weak self] in self?.openAccessSettings() },
            checkAccess: { [weak self] in self?.refreshAccess() },
            completeSetup: { [weak self] in self?.completeSetup() },
            rebuild: { [weak self] in self?.rebuild() }
        )
    }

    // MARK: Tests

    /// Waits for the running index task (tests).
    func waitForIndex() async {
        await runTask?.value
    }
}

/// What the onboarding step and the settings pane need from the plugin.
@MainActor
struct FilesViewModel {
    let state: FilesState
    let settings: FilesSettings
    let openAccessSettings: () -> Void
    let checkAccess: () -> Void
    let completeSetup: () -> Void
    let rebuild: () -> Void
}

/// Values path mode reads from its search task: the Full Disk Access state (updated with every access
/// check) and the hidden-items setting.
final class AccessFlags: Sendable {
    private let values = Mutex((fullDiskAccess: false, includesHidden: false))

    var fullDiskAccess: Bool {
        get { values.withLock { $0.fullDiskAccess } }
        set { values.withLock { $0.fullDiskAccess = newValue } }
    }

    var includesHidden: Bool {
        get { values.withLock { $0.includesHidden } }
        set { values.withLock { $0.includesHidden = newValue } }
    }
}
