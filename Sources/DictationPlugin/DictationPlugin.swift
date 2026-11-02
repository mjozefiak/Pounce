import AppKit
import FluidAudio
import Foundation
import PounceKit
import SwiftUI
import os

/// Voice dictation (spec: Dyktowanie głosowe): records under a global shortcut, transcribes with a speech
/// model that runs inside Pounce, and pastes the text into the app in front. Audio never leaves the Mac
/// and is never written to disk.
///
/// - The shortcut's key-down and key-up go to `DictationController` (tap to toggle, hold to talk), which
///   runs `DictationSession`, the HUD and `TextPaster`.
/// - Models: `Plugins/dictation/Models/<id>/`, downloaded by `ModelManager` on the user's click, or a
///   folder the user points at. The engines never download.
///
/// Settings: `plugins.dictation.*` (see `DictationSettings.Key`). Disabled by default: the feature needs a
/// model download and the microphone.
@MainActor
public final class DictationPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "dictation",
        displayName: LocalizedStringResource("Dictation", comment: "Plugin name of voice dictation"),
        symbolName: "mic",
        order: 40,
        defaultEnabled: false
    )

    static let recordCommandID = "dictation.record"
    static let onboardingStepID = "dictation.setup"

    let context: PluginContext
    let settings: DictationSettings
    private let engine = ParakeetEngine()
    private let authorizer = SystemMicrophoneAuthorizer()
    private let models: ModelManager
    private let hud: DictationHUDPanel
    private let settingsModel: DictationSettingsModel
    private(set) var controller: DictationController?

    public init(context: PluginContext) {
        self.context = context
        let settings = DictationSettings(context.settings)
        self.settings = settings
        let models = ModelManager(
            directory: context.storageDirectory.appending(path: "Models", directoryHint: .isDirectory),
            logger: context.logger)
        self.models = models
        let workspace = context.workspace
        settingsModel = DictationSettingsModel(
            package: ModelCatalog.parakeetUltra, manager: models, settings: settings,
            authorizer: authorizer,
            pickFolder: { Self.chooseModelFolder() },
            openURL: { url in Task { try? await workspace.open(url) } })
        let openSettings = context.openSettings
        // The HUD's buttons call back into the controller, which exists once the plugin is active.
        let relay = ControllerRelay()
        hud = DictationHUDPanel(
            onCancel: { relay.controller?.cancel() }, onOpenSettings: { openSettings() })
        self.relay = relay
    }

    private let relay: ControllerRelay

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

    // MARK: Lifecycle

    public func activate() async throws {
        let context = context
        let settings = settings
        let engine = engine
        let controller = DictationController(
            .init(
                authorizer: authorizer, models: models,
                package: { ModelCatalog.parakeetUltra },
                customFolder: { settings.speechModelFolder },
                makeSession: { folder, onEvent in
                    DictationSession(
                        audio: MicrophoneCapture(deviceUID: settings.inputDevice),
                        vad: LazyVAD(modelFolder: folder.appending(path: ModelCatalog.sileroVADPath)),
                        engine: engine, modelFolder: folder, logger: context.logger, onEvent: onEvent)
                },
                engine: engine,
                paster: TextPaster(
                    pasteboard: context.pasteboard, events: context.events, workspace: context.workspace,
                    permissions: context.permissions, clock: context.clock,
                    restoresClipboard: { settings.restoresClipboard }, logger: context.logger),
                hud: hud, claimEscape: context.claimEscapeKey, openSettings: context.openSettings,
                keepWarm: { settings.keepWarm }, clock: context.clock))
        self.controller = controller
        relay.controller = controller
    }

    public func deactivate() async {
        await controller?.shutDown()
        controller = nil
        relay.controller = nil
    }

    /// "Erase Data": the host deletes `Plugins/dictation/` (models and, later, the history) after this.
    public func eraseData() async throws {}

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
                onKeyEvent: { phase in relay.controller?.keyEvent(phase) })
        ]
    }

    public var requiredPermissions: Set<Permission> { [.microphone, .accessibility] }

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
            DictationSettingsPane(model: settingsModel, recorder: context.makeShortcutRecorder(Self.recordCommandID)))
    }
}

/// Lets the HUD and the command reach the controller, which is created when the plugin activates.
@MainActor
final class ControllerRelay {
    var controller: DictationController?
}

/// Creates the Silero detector when the first audio arrives, so a missing VAD file fails the recording and not
/// the plugin.
actor LazyVAD: VoiceActivityDetector {
    private let modelFolder: URL
    private var detector: SileroVAD?

    init(modelFolder: URL) {
        self.modelFolder = modelFolder
    }

    func process(_ samples: [Float]) async throws -> [VADEvent] {
        if detector == nil {
            detector = try SileroVAD(modelFolder: modelFolder)
        }
        return try await detector?.process(samples) ?? []
    }
}
