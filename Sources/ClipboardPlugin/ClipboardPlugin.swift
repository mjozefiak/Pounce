import Foundation
import PounceKit
import SwiftUI
import os

/// Clipboard history (spec Phase 2): an encrypted history of what the user copies, opened with
/// Command-Shift-V, that pastes the chosen entry into the previous app.
///
/// - Data: `Plugins/clipboard/clipboard.sqlite` (SQLCipher) and `blobs/`, keyed from the master key in
///   the login keychain (`KeyStore`, `HistoryOpener`). Nothing from the clipboard goes to
///   `ranking.sqlite`; the plugin never calls `PluginContext.usage`.
/// - Capture: `PasteboardWatcher` runs only while the plugin is active, recording is not paused and the
///   key is available; it reads nothing while pasteboard access is ask or deny.
/// - Safety controls: pause (menu bar and settings), ignored apps, retention, Clear History,
///   permission and Keychain banners.
///
/// Settings: see `ClipboardSettings.Key`.
@MainActor
public final class ClipboardPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "clipboard",
        displayName: LocalizedStringResource("Clipboard History", comment: "Plugin name of the clipboard history"),
        symbolName: "doc.on.clipboard",
        order: 30
    )

    static let modeID: PanelModeID = "clipboard"
    static let historyCommandID = "clipboard.history"
    static let pauseCommandID = "clipboard.pause"
    static let onboardingStepID = "clipboard.intro"

    let context: PluginContext
    let state = ClipboardState()
    let settings: ClipboardSettings
    let shared = ClipboardShared()
    private(set) var store: ClipStore?
    private(set) var watcher: PasteboardWatcher?
    private var retention: RetentionJob?
    private var sessionTask: Task<Void, Never>?
    private var isActive = false
    private lazy var pasteService = PasteService(
        pasteboard: context.pasteboard,
        events: context.events,
        workspace: context.workspace,
        permissions: context.permissions,
        clock: context.clock,
        logger: context.logger,
        store: { [weak self] in self?.store },
        ownWrite: { [weak self] count in self?.watcher?.ignore(changeCount: count) },
        changed: context.resultsChanged
    )

    public init(context: PluginContext) {
        self.context = context
        self.settings = ClipboardSettings(context.settings)
        settings.onChange = { [weak self] _ in self?.settingsChanged() }
        state.isPaused = settings.isPaused
        state.historyWasReset = settings.historyResetNotice
    }

    // MARK: Lifecycle

    public func activate() async throws {
        isActive = true
        refreshEnvironment()
        let opener = HistoryOpener(directory: context.storageDirectory, keyStore: KeyStore(keychain: context.keychain))
        try openHistory(opener)
        #if DEBUG
        await seedForQA()
        #endif

        let activations = context.workspace.sessionActivations()
        sessionTask = Task { [weak self] in
            for await _ in activations {
                self?.retryIfUnavailable()
            }
        }
        let retention = RetentionJob(clock: context.clock, logger: context.logger)
        self.retention = retention
        retention.start(
            store: { [weak self] in self?.store },
            policy: { [weak self] in self?.settings.retention ?? .default },
            hourly: { [directory = context.storageDirectory, keychain = context.keychain] in
                Task.detached(priority: .utility) {
                    HistoryOpener(directory: directory, keyStore: KeyStore(keychain: keychain))
                        .purgeOldArchives(now: Date())
                }
            },
            changed: { [weak self] in self?.historyChanged() }
        )
        updateRecording()
        refreshCount()
    }

    public func deactivate() async {
        isActive = false
        watcher?.stop()
        watcher = nil
        retention?.stop()
        retention = nil
        sessionTask?.cancel()
        sessionTask = nil
        closeStore()
        state.availability = .inactive
    }

    /// "Erase Data": the host deactivated the plugin and deletes `Plugins/clipboard/` afterwards; the key
    /// in the Keychain is the only thing kept elsewhere.
    public func eraseData() async throws {
        try KeyStore(keychain: context.keychain).delete()
        settings.historyResetNotice = false
        state.historyWasReset = false
    }

    // MARK: Contributions

    public var commands: [PluginCommand] {
        [
            PluginCommand(
                id: Self.historyCommandID,
                title: LocalizedStringResource(
                    "Clipboard History", comment: "Menu item and command that opens the clipboard history"),
                symbolName: "doc.on.clipboard",
                defaultShortcut: KeyShortcut(key: "v", modifiers: [.command, .shift]),
                panelMode: Self.modeID
            ),
            PluginCommand(
                id: Self.pauseCommandID,
                title: settings.isPaused
                    ? LocalizedStringResource(
                        "Resume Clipboard Recording", comment: "Menu item that resumes recording the clipboard")
                    : LocalizedStringResource(
                        "Pause Clipboard Recording", comment: "Menu item that pauses recording the clipboard"),
                symbolName: settings.isPaused ? "play.circle" : "pause.circle"
            ) { [weak self] in
                guard let self else { return }
                self.settings.setPaused(!self.settings.isPaused)
            },
        ]
    }

    public var panelModes: [PanelMode] {
        let state = state
        let actions = statusActions
        let loader = detailLoader
        return [
            PanelMode(
                id: Self.modeID,
                title: Self.manifest.displayName,
                symbolName: Self.manifest.symbolName,
                source: searchSource,
                filters: ClipKind.allCases.map(\.filter),
                makeStatus: { AnyView(ClipboardStatusView(state: state, actions: actions)) },
                makePreview: { candidate in
                    AnyView(ClipPreview(id: ClipPresentation.entryID(candidate.itemKey), load: loader))
                },
                makeEmptyView: { AnyView(ClipboardEmptyView(state: state)) },
                willOpen: { [weak self] in self?.modeWillOpen() }
            )
        ]
    }

    public var onboardingSteps: [OnboardingStep] {
        let state = state
        let actions = statusActions
        return [
            OnboardingStep(
                id: Self.onboardingStepID,
                title: LocalizedStringResource("Clipboard History", comment: "Plugin name of the clipboard history"),
                symbolName: "doc.on.clipboard"
            ) {
                AnyView(ClipboardOnboardingView(state: state, actions: actions))
            }
        ]
    }

    public var requiredPermissions: Set<Permission> { [.accessibility, .pasteboard] }

    public func settingsPane() -> AnyView? {
        AnyView(
            ClipboardSettingsPane(
                state: state,
                settings: settings,
                actions: statusActions,
                recorder: context.makeShortcutRecorder(Self.historyCommandID),
                clearHistory: { [weak self] in await self?.clearHistory() ?? false }
            )
        )
    }

    // MARK: Search and actions

    var searchSource: ClipboardSearchSource {
        ClipboardSearchSource(
            shared: shared,
            paste: { [weak self] id, context in
                guard let self else { return }
                try await self.pasteService.paste(id, context: context)
            },
            copy: { [weak self] id, context in
                guard let self else { return }
                try await self.pasteService.copy(id, context: context)
            },
            delete: { [weak self] id in
                guard let self else { return }
                try await self.delete(id)
            }
        )
    }

    var detailLoader: @Sendable (Int64) async -> ClipDetail? {
        let shared = shared
        return { id in
            guard let store = shared.current else { return nil }
            return await Task.detached(priority: .userInitiated) { try? store.detail(id) }.value
        }
    }

    var statusActions: ClipboardActions {
        ClipboardActions(
            resume: { [weak self] in self?.settings.setPaused(false) },
            retry: { [weak self] in self?.retryIfUnavailable() },
            dismissReset: { [weak self] in self?.dismissResetNotice() },
            openAccessibilitySettings: { [weak self] in self?.open(ClipboardActions.accessibilitySettings) },
            openPasteboardSettings: { [weak self] in self?.open(ClipboardActions.privacySettings) }
        )
    }

    func delete(_ id: Int64) async throws {
        guard let store else { throw ClipboardError.historyUnavailable }
        try await Task.detached(priority: .userInitiated) { try store.delete([id]) }.value
        historyChanged()
    }

    /// "Clear History": an empty database and an empty `blobs/` folder. Returns whether it worked.
    func clearHistory() async -> Bool {
        guard let store else { return false }
        do {
            try await Task.detached(priority: .userInitiated) { try store.deleteAll() }.value
            historyChanged()
            return true
        } catch {
            context.logger.error("Clear History failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }

    // MARK: State

    private func openHistory(_ opener: HistoryOpener) throws {
        switch try opener.open(now: Date()) {
        case .opened(let store, let archive):
            self.store = store
            shared.set(store)
            state.availability = .ready
            if archive != nil {
                context.logger.notice("The clipboard key was missing; the old history was archived")
                settings.historyResetNotice = true
                state.historyWasReset = true
            }
        case .unavailable(let error):
            context.logger.notice("Clipboard history unavailable: \(String(describing: error), privacy: .public)")
            state.availability = error == .locked ? .keychainLocked : .keychainUnavailable
        }
    }

    /// Retries a locked or denied Keychain (session activation, opening the mode, the Retry button).
    func retryIfUnavailable() {
        guard isActive, store == nil else { return }
        do {
            try openHistory(
                HistoryOpener(directory: context.storageDirectory, keyStore: KeyStore(keychain: context.keychain)))
        } catch {
            context.logger.error("Cannot open the clipboard history: \(String(describing: error), privacy: .private)")
        }
        updateRecording()
        if store != nil {
            historyChanged()
        }
    }

    private func modeWillOpen() {
        refreshEnvironment()
        retryIfUnavailable()
        updateRecording()
    }

    /// Re-reads what the system may have changed: Accessibility and pasteboard access.
    func refreshEnvironment() {
        state.pasteAllowed = context.permissions.status(of: .accessibility) == .granted
        shared.setPasteAllowed(state.pasteAllowed)
        state.access = context.pasteboard.accessBehavior
    }

    private func settingsChanged() {
        state.isPaused = settings.isPaused
        updateRecording()
        if let store, let retention {
            let policy = settings.retention
            Task { [weak self] in
                if await retention.run(store: store, policy: policy) {
                    self?.historyChanged()
                }
            }
        }
    }

    /// Starts or stops the watcher to match the state: it runs only while recording is possible.
    func updateRecording() {
        state.isPaused = settings.isPaused
        guard isActive, state.isWatching else {
            watcher?.stop()
            return
        }
        let watcher = watcher ?? makeWatcher()
        self.watcher = watcher
        watcher.start()
    }

    var isWatching: Bool { watcher?.isRunning ?? false }

    /// The watcher saw the pasteboard access setting on a change; the banners follow it.
    private func accessChanged(_ access: PasteboardAccess) {
        guard state.access != access else { return }
        context.logger.notice("Pasteboard access changed to \(access.rawValue, privacy: .public)")
        state.access = access
    }

    private func makeWatcher() -> PasteboardWatcher {
        PasteboardWatcher(
            pasteboard: context.pasteboard,
            workspace: context.workspace,
            clock: context.clock,
            logger: context.logger,
            filter: { [weak self] in self?.settings.captureFilter ?? CaptureFilter(ignoredApps: []) },
            onAccess: { [weak self] access in self?.accessChanged(access) },
            onCapture: { [weak self] capture in self?.store(capture) }
        )
    }

    /// Classifies, hashes and stores a capture in the background (ADR 0002).
    private func store(_ capture: Capture) {
        guard let store else { return }
        let logger = context.logger
        let resultsChanged = context.resultsChanged
        Task.detached(priority: .utility) { [weak self] in
            guard
                let draft = ClipClassifier.draft(
                    from: capture.contents, source: capture.source, capturedAt: capture.capturedAt)
            else { return }
            do {
                try store.insert(draft)
                resultsChanged()
                await self?.refreshCount()
            } catch {
                logger.error("Cannot store a clipboard entry: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func historyChanged() {
        context.resultsChanged()
        refreshCount()
    }

    func refreshCount() {
        guard let store else {
            state.entryCount = 0
            return
        }
        Task { [weak self] in
            let count = await Task.detached { (try? store.count()) ?? 0 }.value
            self?.state.entryCount = count
        }
    }

    private func dismissResetNotice() {
        settings.historyResetNotice = false
        state.historyWasReset = false
    }

    private func closeStore() {
        shared.set(nil)
        do {
            try store?.close()
        } catch {
            context.logger.error("Cannot close the clipboard history: \(String(describing: error), privacy: .private)")
        }
        store = nil
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        let workspace = context.workspace
        Task { try? await workspace.open(url) }
    }

    // MARK: Tests

    /// Waits until pending background stores finished (tests).
    func waitForIdle() async {
        await Task.yield()
    }
}
