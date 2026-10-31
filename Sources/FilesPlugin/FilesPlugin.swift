import Foundation
import Observation
import PounceKit
import SwiftUI
import os

/// What the views show about the index and access.
@MainActor @Observable
final class FilesState {
    var status = IndexStatus.waiting
    var fullDiskAccess = PermissionStatus.notDetermined
    var plan: IndexPlan?
}

/// File search (spec Phase 3): filenames under the home folder and `/Applications` from Pounce's own
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
public final class FilesPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "files",
        displayName: LocalizedStringResource("Files", comment: "Results section and plugin name for files"),
        symbolName: "doc",
        order: 20
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
    private(set) var controller: IndexController?
    private var runTask: Task<Void, Never>?
    private var isActive = false
    private var lastAccessCheck: ContinuousClock.Instant?

    public init(context: PluginContext) {
        self.context = context
        self.settings = FilesSettings(context.settings)
        settings.onChange = { [weak self] in self?.settingsChanged() }
    }

    // MARK: Lifecycle

    public func activate() async throws {
        isActive = true
        refreshAccess()
        startIfReady()
    }

    public func deactivate() async {
        isActive = false
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
        [
            FileSearchSource(
                index: index, usage: context.usage, workspace: context.workspace, pasteboard: context.pasteboard,
                home: settings.home)
        ]
    }

    public var onboardingSteps: [OnboardingStep] {
        let model = viewModel
        return [
            OnboardingStep(
                id: Self.onboardingStepID,
                title: LocalizedStringResource("File Search", comment: "Onboarding step title for file search"),
                symbolName: "doc.text.magnifyingglass"
            ) {
                AnyView(FilesOnboardingView(model: model))
            }
        ]
    }

    public var requiredPermissions: Set<Permission> { [.fullDiskAccess] }

    public func settingsPane() -> AnyView? {
        AnyView(FilesSettingsPane(model: viewModel))
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
                        "File search starts once you choose how Pounce may read your files.",
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

    private func restart(_ plan: IndexPlan) {
        state.plan = plan
        let previous = runTask
        previous?.cancel()
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
        let directory = context.storageDirectory
        let previous = runTask
        previous?.cancel()
        runTask = nil
        let plan = settings.plan(fullDiskAccess: state.fullDiskAccess == .granted)
        Task {
            await previous?.value
            IndexSnapshot.delete(in: directory)
            restart(plan)
        }
    }

    /// The Full Disk Access step was finished or skipped, or "Start Indexing" was pressed.
    func completeSetup() {
        refreshAccess()
        settings.completeSetup()
    }

    private func settingsChanged() {
        startIfReady()
        context.resultsChanged()
    }

    // MARK: Access

    /// Re-reads Full Disk Access and replans when it changed.
    func refreshAccess() {
        lastAccessCheck = .now
        let status = context.permissions.status(of: .fullDiskAccess)
        guard status != state.fullDiskAccess else { return }
        state.fullDiskAccess = status
        startIfReady()
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
