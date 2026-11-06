import AppKit
import Foundation
import LintelKit
import LintelSpeech
import LintelUI
import SwiftUI
import os

/// Voice dictation (spec: Dyktowanie głosowe): records under a global shortcut, transcribes with a speech
/// model that runs inside Lintel, and pastes the text into the app in front. Audio never leaves the Mac
/// and is never written to disk.
///
/// - The shortcut's key-down and key-up go to `DictationController` (tap to toggle, hold to talk), which
///   runs `DictationSession`, the HUD and `TextPaster`.
/// - Models: `Models/speech/<id>/`, downloaded by `ModelManager` on the user's click, or a
///   folder the user points at. The engines never download.
///
/// Settings: `plugins.dictation.*` (see `DictationSettings.Key`). Disabled by default: the feature needs a
/// model download and the microphone.
@MainActor
public final class DictationPlugin: LintelPlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "dictation",
        displayName: LocalizedStringResource("Dictation", comment: "Plugin name of voice dictation"),
        symbolName: "mic",
        order: 40,
        defaultEnabled: false,
        settingsGroup: .voice,
        summary: LocalizedStringResource(
            "Speak instead of typing.", comment: "Settings → Features: what Dictation does")
    )

    static let recordCommandID = "dictation.record"
    static let pasteLastRawCommandID = "dictation.pasteLastRaw"
    static let historyCommandID = "dictation.history"
    static let historyModeID: PanelModeID = "dictation.history"
    static let onboardingStepID = "dictation.setup"

    let context: PluginContext
    let settings: DictationSettings
    private let engine: SwitchingEngine
    private let authorizer: any MicrophoneAuthorizer
    private let models: ModelManager
    /// Downloads the built-in formatting models into `Models/llm/` (used by the settings in step 4.4).
    let llmModels: ModelManager
    nonisolated static let llmDirectoryName = "llm"
    nonisolated static let speechDirectoryName = "speech"
    /// The built-in formatting model, loaded on demand and freed after the keep-warm time.
    private let builtInLLM: KeepWarmRuntime
    private let hud: DictationHUDPanel
    private let settingsModel: DictationSettingsModel
    private let formattingModel: FormattingSettingsModel
    private let transport: any HTTPTransport
    let history: DictationHistory
    /// The history as a Notes source (`noteSources`); its change streams end on `deactivate()`.
    let noteSource: DictationNoteSource
    private let noteChanges = NoteChangeHub()
    private let historyModel: HistorySettingsModel
    private(set) var controller: DictationController?
    /// Where app activations are posted (tests use their own centre).
    var appActivationCenter: NotificationCenter = .default
    private var activationObserver: AppActivationObserver?

    public convenience init(context: PluginContext) {
        self.init(context: context, makeBuiltInLLM: nil)
    }

    /// `makeBuiltInLLM` replaces the built-in formatting runtime (tests); `nil` is the real one over llama.cpp.
    /// `authorizer` replaces the system's microphone permission (tests).
    init(
        context: PluginContext, makeBuiltInLLM: ((DictationSettings, ModelManager) -> KeepWarmRuntime)?,
        authorizer: any MicrophoneAuthorizer = SystemMicrophoneAuthorizer()
    ) {
        self.context = context
        self.authorizer = authorizer
        let settings = DictationSettings(context.settings)
        self.settings = settings
        engine = SwitchingEngine(
            engines: [
                ModelCatalog.parakeetUltra.id: ParakeetEngine(),
                ModelCatalog.whisperLargeV3Turbo.id: WhisperKitEngine(language: { settings.speechLanguage }),
            ],
            selected: { settings.speechModelID })
        let models = ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(path: Self.speechDirectoryName, directoryHint: .isDirectory),
            logger: context.logger)
        self.models = models
        // Formatting models (ADR 0005) live next to the speech models in the shared `Models/` folder (ADR 0006).
        let llmModels = ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(path: Self.llmDirectoryName, directoryHint: .isDirectory),
            logger: context.logger)
        self.llmModels = llmModels
        builtInLLM =
            makeBuiltInLLM?(settings, llmModels)
            ?? KeepWarmRuntime(
                runtime: LlamaRuntime(),
                modelURL: {
                    let model = settings.builtInLLMModel
                    guard let folder = await llmModels.location(of: model.package).folder,
                        let file = model.fileURL(in: folder)
                    else { throw LlamaError.modelNotFound }
                    return file
                },
                keepWarm: { settings.keepWarm }, lease: .shared)
        let workspace = context.workspace
        settingsModel = DictationSettingsModel(
            package: ModelCatalog.package(id: settings.speechModelID) ?? ModelCatalog.parakeetUltra, manager: models,
            settings: settings,
            authorizer: authorizer,
            pickFolder: { Self.chooseModelFolder() },
            openURL: { url in Task { try? await workspace.open(url) } })
        // The banner reads the model's place and the microphone; a change makes the shell read it again.
        let resultsChanged = context.resultsChanged
        settingsModel.onStatusChange = { resultsChanged() }
        let noteChanges = noteChanges
        history = DictationHistory(
            directory: context.storageDirectory, keychain: context.keychain, settings: settings,
            clock: context.clock, logger: context.logger,
            changed: {
                resultsChanged()
                noteChanges.notify()
            })
        noteSource = DictationNoteSource(history: history, hub: noteChanges)
        historyModel = HistorySettingsModel(settings: settings, history: history)
        let transport = LoopbackTransport()
        self.transport = transport
        formattingModel = FormattingSettingsModel(
            settings: settings, transport: transport, llmModels: llmModels, runtime: builtInLLM)
        let openSettings = context.openSettings
        let openModels = context.openModels
        // The HUD's buttons call back into the controller, which exists once the plugin is active.
        let relay = ControllerRelay()
        // A missing or broken speech model goes to the Models pane; the microphone problem goes to Settings.
        hud = DictationHUDPanel(
            onCancel: { relay.controller?.cancel() }, onOpenSettings: { openSettings() },
            onOpenModels: { openModels(settings.speechModelID) })
        self.relay = relay
    }

    /// Internal so tests can hand `modelUsage` a controller.
    let relay: ControllerRelay

    private static func chooseModelFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button of the model folder picker")
        panel.message = String(
            localized: "Choose the folder that contains the speech model's files.",
            comment: "Message of the model folder picker")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// The formatter for a new session: none in raw mode, else the user's server or the built-in model.
    private static func formatter(
        settings: DictationSettings, transport: any HTTPTransport, builtIn: KeepWarmRuntime, logger: Logger
    ) -> (any TextFormatter)? {
        guard settings.mode == .cleanup else { return nil }
        switch settings.llmSource {
        case .server:
            return LocalLLMFormatter(transport: transport, target: { settings.llmTarget }, logger: logger)
        case .builtIn:
            return BuiltInFormatter(runtime: builtIn, logger: logger)
        }
    }

    // MARK: Lifecycle

    public func activate() async throws {
        let context = context
        let settings = settings
        let engine = engine
        let lease = SpeechEngineLease.shared
        let transport = transport
        let history = history
        let builtInLLM = builtInLLM
        let controller = DictationController(
            .init(
                authorizer: authorizer, models: models,
                package: { ModelCatalog.package(id: settings.speechModelID) ?? ModelCatalog.parakeetUltra },
                customFolder: { settings.speechModelFolder },
                makeSession: { folder, onEvent in
                    DictationSession(
                        audio: MicrophoneCapture(deviceUID: settings.inputDevice),
                        vad: LazyVAD(modelFolder: folder.appending(path: ModelCatalog.sileroVADPath)),
                        engine: engine,
                        formatter: Self.formatter(
                            settings: settings, transport: transport, builtIn: builtInLLM, logger: context.logger),
                        modelFolder: folder, lease: lease, modelID: settings.speechModelID,
                        keepWarm: { settings.keepWarm }, logger: context.logger, onEvent: onEvent)
                },
                lease: lease,
                paster: TextPaster(
                    pasteboard: context.pasteboard, events: context.events, workspace: context.workspace,
                    permissions: context.permissions, clock: context.clock,
                    restoresClipboard: { settings.restoresClipboard }, logger: context.logger),
                hud: hud, claimEscape: context.claimEscapeKey, openSettings: context.openSettings,
                clock: context.clock,
                recordHistory: { history.record($0) },
                frontmostBundleID: { context.workspace.frontmostApplication?.bundleIdentifier },
                formatMode: { settings.mode == .cleanup ? .clean : .raw },
                speechModelID: { settings.speechModelID },
                formatterModel: { settings.llmSource == .builtIn ? settings.builtInLLMModel.id : settings.llmModel }))
        self.controller = controller
        relay.controller = controller
        history.open()
        // The banner's state is known before the shell first reads it; coming back from System Settings or from
        // a download elsewhere re-reads it.
        await settingsModel.refreshStatus()
        let model = settingsModel
        activationObserver = AppActivationObserver(center: appActivationCenter) {
            Task { await model.refreshStatus() }
        }
    }

    public func deactivate() async {
        // The streams end when this method returns, after the history is closed: a read that started earlier may
        // still answer, a read after the history closed throws.
        defer { noteChanges.finishAll() }
        activationObserver?.stop()
        activationObserver = nil
        await controller?.shutDown()
        await builtInLLM.unload()
        history.close()
        controller = nil
        relay.controller = nil
    }

    /// "Erase Data": the host deletes `Plugins/dictation/` (the history) after this. Removes the history's
    /// Keychain item; the folder (`dictation.sqlite`) is deleted by the host. Downloaded models live in the
    /// shared `Models/` folder (ADR 0006) and stay; "Remove model" in Settings deletes them.
    public func eraseData() async throws {
        try history.erase()
    }

    // MARK: Contributions

    public var commands: [PluginCommand] {
        let relay = relay
        return [
            PluginCommand(
                id: Self.recordCommandID,
                title: LocalizedStringResource("Dictate", comment: "Menu item and command that starts dictation"),
                symbolName: "mic",
                defaultShortcut: KeyShortcut(key: "d", modifiers: [.control, .option]),
                run: { relay.controller?.menu() },
                onKeyEvent: { phase in relay.controller?.keyEvent(phase) }),
            PluginCommand(
                id: Self.pasteLastRawCommandID,
                title: LocalizedStringResource(
                    "Paste raw version of the last dictation",
                    comment: "Menu item and command that pastes the last dictation without formatting"),
                symbolName: "text.badge.minus",
                run: { relay.controller?.pasteLastRaw() }),
            PluginCommand(
                id: Self.historyCommandID,
                title: LocalizedStringResource(
                    "Dictation History", comment: "Menu item and command that opens the dictation history"),
                symbolName: "clock.arrow.circlepath",
                panelMode: Self.historyModeID),
        ]
    }

    public var panelModes: [PanelMode] {
        let history = history
        let relay = relay
        var source = DictationHistorySource(
            store: { history.storeBox.value },
            paste: { text in await relay.pasteFromHistory(text) },
            delete: { id in try await history.delete([id]) })
        #if DEBUG
        let openNote = context.openNote
        source.openInNotes = { row in
            guard let storeID = history.storeID else { return }
            _ = await openNote(DictationNoteSource.key(storeID: storeID, row: row))
        }
        #endif
        return [
            PanelMode(
                id: Self.historyModeID,
                title: LocalizedStringResource(
                    "Dictation History", comment: "Menu item and command that opens the dictation history"),
                symbolName: "clock.arrow.circlepath",
                source: source,
                filters: [
                    PanelModeFilter(
                        id: HistoryFilter.all.rawValue,
                        title: LocalizedStringResource("All", comment: "Dictation history filter"),
                        symbolName: "list.bullet"),
                    PanelModeFilter(
                        id: HistoryFilter.formatted.rawValue,
                        title: LocalizedStringResource("Formatted", comment: "Dictation history filter"),
                        symbolName: "wand.and.stars"),
                    PanelModeFilter(
                        id: HistoryFilter.raw.rawValue,
                        title: LocalizedStringResource("Raw", comment: "Dictation history filter"),
                        symbolName: "text.alignleft"),
                ],
                makeStatus: { AnyView(DictationHistoryStatusView(history: history)) },
                makePreview: { candidate in
                    AnyView(
                        DictationPreview(
                            id: DictationPresentation.entryID(candidate.itemKey),
                            load: { id in try? history.storeBox.value?.entry(id) }))
                },
                makeEmptyView: { AnyView(DictationHistoryEmptyView(history: history)) })
        ]
    }

    public var noteSources: [any NoteSource] { [noteSource] }

    /// Offers a history entry to the shell's Notes workspace (`PluginContext.openNote`). `true` only when a
    /// section took it; the default handler returns `false`. The history's "Open in Lintel" action (⌘O, inside
    /// `#if DEBUG` until step 7.1) goes through the same context call.
    func openNote(entryID: Int64) -> Bool {
        guard let storeID = history.storeID else { return false }
        return context.openNote(DictationNoteSource.key(storeID: storeID, row: entryID))
    }

    public var requiredPermissions: Set<Permission> { [.microphone, .accessibility] }

    /// The models dictation uses, for the shell's Models pane (spec `2026-11-04-lintel-main-window`, step 3.2):
    /// the selected speech model (required unless the user chose a folder for it) and the built-in formatting model
    /// (optional, selected only while the built-in source is chosen; in use while a request holds it, as the
    /// Formatting settings check today).
    public var modelUsage: [ModelUsage] {
        let settings = settings
        let relay = relay
        let builtInLLM = builtInLLM
        let speech = ModelCatalog.package(id: settings.speechModelID) ?? ModelCatalog.parakeetUltra
        return [
            ModelUsage(
                packageID: speech.id, kind: .speech,
                role: LocalizedStringResource(
                    "Dictation", comment: "Models pane: what Dictation uses the speech model for"),
                // With a chosen folder the downloaded copy is not needed; the pane shows the folder's state.
                isRequired: settings.speechModelFolder == nil, isSelected: true,
                chooseFolder: { settings.setSpeechModelFolder($0) },
                customFolder: settings.speechModelFolder,
                isInUse: { relay.controller?.isBusy ?? false }),
            ModelUsage(
                packageID: settings.builtInLLMModel.id, kind: .llm,
                role: LocalizedStringResource(
                    "Formatting", comment: "Models pane: what Dictation uses the language model for"),
                isRequired: false, isSelected: settings.llmSource == .builtIn,
                isInUse: { await builtInLLM.isInUse() }),
        ]
    }

    public var onboardingSteps: [OnboardingStep] {
        let model = settingsModel
        let permissions = context.permissions
        return [
            OnboardingStep(
                id: Self.onboardingStepID,
                title: LocalizedStringResource("Dictation", comment: "Plugin name of voice dictation"),
                symbolName: "mic",
                text: DictationSetupView.text
            ) {
                AnyView(
                    DictationSetupView(
                        model: model, accessibilityAllowed: { permissions.status(of: .accessibility) == .granted })
                )
            }
        ]
    }

    /// The main window's banner (prototype `set-dictation`). The shell reads it only while the plugin is active
    /// and while the view draws, so it only reads: the model's place and the microphone are re-read on
    /// activation, when the pane appears and when Lintel becomes the active app, and a change signals
    /// `resultsChanged`. A denied microphone or Accessibility is listed by the shell's derivation; the title's
    /// number counts it (`ThingsToDo`).
    public var settingsStatus: SettingsStatus? {
        let model = settingsModel
        let history = history
        let denied = ThingsToDo.deniedPermissions(
            requiredPermissions, countedByPlugin: model.microphone == .notDetermined ? [.microphone] : [],
            reader: context.permissions)
        return Self.settingsStatus(
            location: model.location, microphone: model.microphone, history: history.status,
            modelTitle: model.package.title, packageID: model.package.id, deniedPermissions: denied,
            allowMicrophone: { await model.requestMicrophoneAccess() },
            retryHistory: { history.open() })
    }

    /// The banner ids of the plugin's own actions.
    nonisolated static let allowMicrophoneActionID = "allowMicrophone"
    nonisolated static let retryHistoryActionID = "retry"

    /// Most important first: what keeps dictation from working (the speech model, a microphone macOS has not
    /// asked about yet; "N things to do" as in the prototype), then a history that cannot be opened (dictation
    /// still works; Try Again, nothing is deleted), else "Ready". `deniedPermissions` is how many denied required
    /// permissions the shell adds to the detail; the number in the title counts them too.
    static func settingsStatus(
        location: ModelLocation,
        microphone: MicrophoneAccess,
        history: DictationHistory.Status,
        modelTitle: String,
        packageID: String,
        deniedPermissions: Int = 0,
        allowMicrophone: @escaping @MainActor @Sendable () async -> Void,
        retryHistory: @escaping @MainActor @Sendable () async -> Void
    ) -> SettingsStatus? {
        let needsModel = location.folder == nil
        let needsMicrophone = microphone == .notDetermined
        let getModel = SettingsStatusAction(
            title: LocalizedStringResource(
                "Get It in Models", comment: "Settings banner button: opens the Models pane on the missing model"),
            destination: .models(packageID: packageID))
        let askMicrophone = SettingsStatusAction(
            title: LocalizedStringResource("Allow Microphone", comment: "Button that asks for microphone access"),
            destination: .plugin(id: allowMicrophoneActionID, perform: allowMicrophone))
        let title = ThingsToDo.title((needsModel ? 1 : 0) + (needsMicrophone ? 1 : 0) + deniedPermissions)
        switch (needsModel, needsMicrophone) {
        case (true, true):
            return SettingsStatus(
                level: .attention, title: title,
                detail: LocalizedStringResource(
                    "Allow the microphone and get the speech model.",
                    comment: "Settings banner detail: the microphone was not asked yet and the speech model is missing"
                ),
                fix: [askMicrophone, getModel])
        case (true, false):
            let detail: LocalizedStringResource
            if case .customFolderUnavailable = location {
                detail = LocalizedStringResource(
                    "The speech model’s folder isn’t available.",
                    comment: "Settings → Dictation banner detail: the folder the user chose for the model is gone")
            } else {
                detail = LocalizedStringResource(
                    "The speech model isn’t installed.", comment: "Settings banner detail: the speech model is missing")
            }
            return SettingsStatus(level: .attention, title: title, detail: detail, fix: [getModel])
        case (false, true):
            return SettingsStatus(
                level: .attention, title: title,
                detail: LocalizedStringResource(
                    "Allow the microphone so Lintel can hear you.",
                    comment: "Settings → Dictation banner detail: macOS has not asked for the microphone yet"),
                fix: [askMicrophone])
        case (false, false):
            break
        }
        let paused = LocalizedStringResource(
            "History is paused (dictation)", defaultValue: "History is paused",
            comment: "Settings → Dictation banner when the dictation history cannot be opened")
        let tryAgain = SettingsStatusAction(
            title: LocalizedStringResource(
                "Try Again (dictation history)", defaultValue: "Try Again",
                comment: "Settings → Dictation banner button that opens the dictation history again"),
            destination: .plugin(id: retryHistoryActionID, perform: retryHistory))
        switch history {
        case .unavailable:
            return SettingsStatus(
                level: .attention, title: paused,
                detail: LocalizedStringResource(
                    "Lintel can’t read the history’s key. Nothing was deleted.",
                    comment: "Settings → Dictation banner detail when the history key cannot be read"),
                fix: [tryAgain])
        case .failed:
            return SettingsStatus(
                level: .attention, title: paused,
                detail: LocalizedStringResource(
                    "The history couldn’t be opened. Dictation still works.",
                    comment: "Settings → Dictation banner detail when the history database cannot be opened"),
                fix: [tryAgain])
        case .closed, .ready:
            break
        }
        return SettingsStatus(
            level: .ok,
            title: LocalizedStringResource("Ready", comment: "Settings banner level, spoken"),
            detail: LocalizedStringResource(
                "Speech model: \(modelTitle).",
                comment: "Settings → Dictation banner detail when dictation is ready: the speech model's name"))
    }

    public func settingsPane() -> AnyView? {
        AnyView(
            DictationSettingsPane(
                model: settingsModel, formatting: formattingModel, history: historyModel,
                recorder: context.makeShortcutRecorder(Self.recordCommandID), isActive: controller != nil,
                openModels: context.openModels))
    }
}

/// Lets the HUD and the command reach the controller, which is created when the plugin activates.
@MainActor
final class ControllerRelay {
    var controller: DictationController?

    func pasteFromHistory(_ text: String) async {
        await controller?.pasteFromHistory(text)
    }
}
