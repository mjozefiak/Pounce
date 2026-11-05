import Foundation
import LintelKit
import LintelUI
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
public final class ClipboardPlugin: LintelPlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "clipboard",
        displayName: LocalizedStringResource("Clipboard History", comment: "Plugin name of the clipboard history"),
        symbolName: "doc.on.clipboard",
        order: 30,
        settingsGroup: .search
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
    /// Where app activations are posted (tests use their own centre).
    var appActivationCenter: NotificationCenter = .default
    private var activationObserver: AppActivationObserver?
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
        // Coming back from System Settings: Accessibility and pasteboard access may have changed.
        activationObserver = AppActivationObserver(center: appActivationCenter) { [weak self] in
            self?.recheckEnvironment()
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
        activationObserver?.stop()
        activationObserver = nil
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

    /// The main window's banner (prototypes `set-clipboard` and `set-error`), read by the shell only while the
    /// plugin is active and while the view draws, so it only reads: pasteboard access is re-checked when the pane
    /// appears and when Lintel becomes the active app (`recheckEnvironment()`). Accessibility is left to the
    /// shell, which derives it from `requiredPermissions`.
    public var settingsStatus: SettingsStatus? {
        let actions = statusActions
        return Self.settingsStatus(
            availability: state.availability, access: state.access, isPaused: state.isPaused,
            historyWasReset: state.historyWasReset, entryCount: state.entryCount,
            retry: { actions.retry() }, resume: { actions.resume() }, dismissReset: { actions.dismissReset() })
    }

    /// The banner ids of the plugin's own actions.
    nonisolated static let retryActionID = "retry"
    nonisolated static let resumeActionID = "resume"
    nonisolated static let dismissResetActionID = "dismissReset"

    /// Most important first: a key that cannot be read (error, Try Again; nothing is deleted), pasteboard access
    /// that keeps anything from being recorded, the reset notice, a paused recording, else "Ready · Recording.
    /// N entries."
    nonisolated static func settingsStatus(
        availability: HistoryAvailability,
        access: PasteboardAccess,
        isPaused: Bool,
        historyWasReset: Bool,
        entryCount: Int,
        retry: @escaping @MainActor @Sendable () async -> Void,
        resume: @escaping @MainActor @Sendable () async -> Void,
        dismissReset: @escaping @MainActor @Sendable () async -> Void
    ) -> SettingsStatus? {
        let tryAgain = SettingsStatusAction(
            title: LocalizedStringResource("Try Again", comment: "Button that retries opening the clipboard history"),
            destination: .plugin(id: retryActionID, perform: retry))
        let paused = LocalizedStringResource(
            "History is paused", comment: "Settings → Clipboard banner when the history key cannot be read")
        switch availability {
        case .inactive:
            return nil
        case .keychainLocked:
            return SettingsStatus(
                level: .error, title: paused,
                detail: LocalizedStringResource(
                    "The keychain is locked. Nothing was deleted.",
                    comment: "Settings → Clipboard banner detail while the login keychain is locked"),
                fix: [tryAgain])
        case .keychainUnavailable:
            return SettingsStatus(
                level: .error, title: paused,
                detail: LocalizedStringResource(
                    "Lintel can’t read the key. Nothing was deleted.",
                    comment: "Settings → Clipboard banner detail when the keychain denied access to the key"),
                fix: [tryAgain])
        case .ready:
            break
        }
        let openPrivacy = SettingsStatusAction(
            title: LocalizedStringResource(
                "Open Privacy Settings", comment: "Button that opens Privacy & Security settings"),
            destination: .systemSettings(.pasteboard))
        switch access {
        case .alwaysDeny:
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "Nothing is recorded", comment: "Settings → Clipboard banner when the clipboard cannot be read"),
                detail: LocalizedStringResource(
                    "Lintel isn’t allowed to read the clipboard.",
                    comment: "Settings → Clipboard banner detail when pasteboard access is denied"),
                fix: [openPrivacy])
        case .ask:
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "Nothing is recorded", comment: "Settings → Clipboard banner when the clipboard cannot be read"),
                detail: LocalizedStringResource(
                    "macOS asks before every read. Allow Lintel in Privacy & Security.",
                    comment: "Settings → Clipboard banner detail when pasteboard access asks each time"),
                fix: [openPrivacy])
        case .alwaysAllow, .systemDefault:
            break
        }
        if historyWasReset {
            return SettingsStatus(
                level: .attention,
                title: LocalizedStringResource(
                    "A new history was started", comment: "Settings → Clipboard banner after the history was reset"),
                detail: LocalizedStringResource(
                    "The key was missing. The old history stays encrypted and is deleted after 30 days.",
                    comment: "Settings → Clipboard banner detail after the history was reset"),
                fix: [
                    SettingsStatusAction(
                        title: LocalizedStringResource("Dismiss", comment: "Button that dismisses a notice"),
                        destination: .plugin(id: dismissResetActionID, perform: dismissReset))
                ])
        }
        if isPaused {
            return SettingsStatus(
                level: .neutral,
                title: LocalizedStringResource(
                    "Recording is paused (banner)", defaultValue: "Recording is paused",
                    comment: "Settings → Clipboard banner while recording is paused"),
                detail: LocalizedStringResource(
                    "\(entryCount) entries. Nothing new is added.",
                    comment: "Settings → Clipboard banner detail while paused: the number of entries"),
                fix: [
                    SettingsStatusAction(
                        title: LocalizedStringResource("Resume", comment: "Button that resumes clipboard recording"),
                        destination: .plugin(id: resumeActionID, perform: resume))
                ])
        }
        return SettingsStatus(
            level: .ok,
            title: LocalizedStringResource("Ready", comment: "Settings banner level, spoken"),
            detail: LocalizedStringResource(
                "Recording. \(entryCount) entries.",
                comment: "Settings → Clipboard banner detail while recording: the number of entries"))
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
            recheck: { [weak self] in self?.recheckEnvironment() },
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

    /// Re-reads what the system may have changed: Accessibility and pasteboard access. Returns whether either
    /// changed.
    @discardableResult func refreshEnvironment() -> Bool {
        let pasteAllowed = context.permissions.status(of: .accessibility) == .granted
        let access = context.pasteboard.accessBehavior
        let changed = pasteAllowed != state.pasteAllowed || access != state.access
        state.pasteAllowed = pasteAllowed
        shared.setPasteAllowed(pasteAllowed)
        state.access = access
        return changed
    }

    /// The pane appeared or Lintel became the active app: re-reads the environment, starts or stops recording to
    /// match, and tells the shell when the banner changes. Does nothing while the plugin is off.
    func recheckEnvironment() {
        guard isActive else { return }
        guard refreshEnvironment() else { return }
        updateRecording()
        context.resultsChanged()
    }

    private func settingsChanged() {
        let pauseChanged = state.isPaused != settings.isPaused
        state.isPaused = settings.isPaused
        updateRecording()
        if pauseChanged {
            // The Settings banner ("Recording is paused") follows.
            context.resultsChanged()
        }
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
        context.resultsChanged()
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
        Task.detached(priority: .utility) { [weak self] in
            guard
                let draft = ClipClassifier.draft(
                    from: capture.contents, source: capture.source, capturedAt: capture.capturedAt)
            else { return }
            do {
                try store.insert(draft)
                // One signal per copy, once the count is known (the list and the Settings banner both follow).
                await self?.refreshCount(changed: true)
            } catch {
                logger.error("Cannot store a clipboard entry: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private func historyChanged() {
        refreshCount(changed: true)
    }

    /// Reads the entry count again and signals `resultsChanged` once: when the count changed (the Settings
    /// banner counts the entries) or when `changed` says the history did.
    func refreshCount(changed: Bool = false) {
        guard let store else {
            state.entryCount = 0
            if changed { context.resultsChanged() }
            return
        }
        Task { [weak self] in
            let count = await Task.detached { (try? store.count()) ?? 0 }.value
            guard let self else { return }
            let countChanged = self.state.entryCount != count
            self.state.entryCount = count
            if changed || countChanged {
                self.context.resultsChanged()
            }
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
