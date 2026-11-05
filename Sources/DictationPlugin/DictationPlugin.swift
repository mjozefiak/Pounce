import AppKit
import Foundation
import LintelKit
import LintelSpeech
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
        settingsGroup: .voice
    )

    static let recordCommandID = "dictation.record"
    static let pasteLastRawCommandID = "dictation.pasteLastRaw"
    static let historyCommandID = "dictation.history"
    static let historyModeID: PanelModeID = "dictation.history"
    static let onboardingStepID = "dictation.setup"

    let context: PluginContext
    let settings: DictationSettings
    private let engine: SwitchingEngine
    private let authorizer = SystemMicrophoneAuthorizer()
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
    private let historyModel: HistorySettingsModel
    private(set) var controller: DictationController?

    public convenience init(context: PluginContext) {
        self.init(context: context, makeBuiltInLLM: nil)
    }

    /// `makeBuiltInLLM` replaces the built-in formatting runtime (tests); `nil` is the real one over llama.cpp.
    init(context: PluginContext, makeBuiltInLLM: ((DictationSettings, ModelManager) -> KeepWarmRuntime)?) {
        self.context = context
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
        history = DictationHistory(
            directory: context.storageDirectory, keychain: context.keychain, settings: settings,
            clock: context.clock, logger: context.logger, changed: context.resultsChanged)
        historyModel = HistorySettingsModel(settings: settings, history: history)
        let transport = LoopbackTransport()
        self.transport = transport
        formattingModel = FormattingSettingsModel(
            settings: settings, transport: transport, llmModels: llmModels, runtime: builtInLLM)
        let openSettings = context.openSettings
        let openModels = context.openModels
        // The HUD's buttons call back into the controller, which exists once the plugin is active.
        let relay = ControllerRelay()
        // A missing or broken speech model goes to the Models pane (in the old window: this pane, which shows the
        // model card); the microphone problem goes to Settings as before.
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
    }

    public func deactivate() async {
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
        let source = DictationHistorySource(
            store: { history.storeBox.value },
            paste: { text in await relay.pasteFromHistory(text) },
            delete: { id in try await history.delete([id]) })
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
                // A chosen folder is not seen by the Models pane, so it must not count as a missing model.
                isRequired: settings.speechModelFolder == nil, isSelected: true,
                chooseFolder: { settings.setSpeechModelFolder($0) },
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
                symbolName: "mic"
            ) {
                AnyView(
                    DictationSetupView(
                        model: model, accessibilityAllowed: { permissions.status(of: .accessibility) == .granted })
                )
            }
        ]
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
