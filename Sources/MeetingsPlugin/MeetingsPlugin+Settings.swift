import AppKit
import LintelKit
import LintelSpeech
import SwiftUI

/// The settings pane, the setup step and the Permissions test of `MeetingsPlugin`, with the models they share.
@MainActor
final class MeetingsUI {
    static let recordCommandID = "meetings.record"
    static let onboardingStepID = "meetings.setup"
    /// `Models/speech` is shared with dictation (ADR 0006); the diarization model has a folder of its own.
    static let speechDirectoryName = "speech"
    static let diarizationDirectoryName = "diarization"
    /// The built-in language models are shared with dictation's formatting (`Models/llm/`).
    static let llmDirectoryName = "llm"

    let model: MeetingsSettingsModel
    /// The "in use" check and the removal reservation the model cards use; the Models pane gets the same through
    /// `MeetingsPlugin.modelUsage`.
    let usage: MeetingsModelUsage
    /// `Models/llm/`, shared with dictation; the notes model's file is found here.
    let llmManager: ModelManager

    init(
        context: PluginContext, settings: MeetingsSettings, library: MeetingsLibrary, activity: MeetingActivity,
        authorizer: any MicrophoneAuthorizer = SystemMicrophoneAuthorizer(),
        manager: @MainActor (URL) -> ModelManager = { url in
            ModelManagers.shared.manager(for: url)
        },
        makeSelfTest: @escaping @MainActor () -> SystemAudioSelfTest = {
            SystemAudioSelfTest(backend: CoreAudioProcessTapBackend(), player: AVAudioEngineTonePlayer())
        },
        pickFolder: @escaping @MainActor () -> URL? = { MeetingsUI.chooseModelFolder() },
        usage: MeetingsModelUsage? = nil, notes service: NotesService
    ) {
        let usage =
            usage
            ?? .live(activity: activity, isProcessing: { [weak library] in library?.isProcessing ?? false })
        self.usage = usage
        let speechManager = manager(
            context.modelsDirectory.appending(path: Self.speechDirectoryName, directoryHint: .isDirectory))
        let diarizationManager = manager(
            context.modelsDirectory.appending(path: Self.diarizationDirectoryName, directoryHint: .isDirectory))
        let speech = MeetingsModelCardModel(
            package: ModelCatalog.package(id: settings.speechModelID) ?? ModelCatalog.parakeetUltra,
            manager: speechManager, usage: usage, customFolder: { settings.speechModelFolder },
            setCustomFolder: { settings.setSpeechModelFolder($0) }, pickFolder: pickFolder)
        let diarization = MeetingsModelCardModel(
            package: ModelCatalog.diarizationCommunity1, manager: diarizationManager, usage: usage,
            customFolder: { settings.diarizationModelFolder },
            setCustomFolder: { settings.setDiarizationModelFolder($0) }, pickFolder: pickFolder)
        let llmManager = manager(
            context.modelsDirectory.appending(path: Self.llmDirectoryName, directoryHint: .isDirectory))
        self.llmManager = llmManager
        let workspace = context.workspace
        model = MeetingsSettingsModel(
            settings: settings, library: library,
            privacy: MeetingsPrivacyActions(
                library: library, spool: SpoolStorage(pluginDirectory: context.storageDirectory),
                activity: activity, changed: context.resultsChanged),
            speech: speech, diarization: diarization,
            systemAudioTest: SystemAudioTestModel(makeTest: makeSelfTest, blocked: { activity.isActive }),
            notes: NotesSettingsModel(settings: settings, service: service, manager: llmManager),
            authorizer: authorizer, openURL: { url in Task { try? await workspace.open(url) } })
    }

    private static func chooseModelFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose", comment: "Button of the model folder picker")
        panel.message = String(
            localized: "Choose the folder that contains the model's files.",
            comment: "Message of the meetings model folder picker")
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension MeetingsPlugin {
    public var onboardingSteps: [OnboardingStep] {
        let model = ui.model
        return [
            OnboardingStep(
                id: MeetingsUI.onboardingStepID,
                title: LocalizedStringResource("Meetings", comment: "Plugin name of meeting transcription"),
                symbolName: "person.2.wave.2"
            ) {
                AnyView(MeetingsSetupView(model: model))
            }
        ]
    }

    public func settingsPane() -> AnyView? {
        // The recorder needs its command, which arrives with the record command (step 1.10).
        let recorder =
            commands.contains { $0.id == MeetingsUI.recordCommandID }
            ? context.makeShortcutRecorder(MeetingsUI.recordCommandID) : nil
        return AnyView(
            MeetingsSettingsPane(
                model: ui.model, recorder: recorder, isActive: controller != nil, openModels: context.openModels))
    }

    public func permissionAccessory(for permission: Permission) -> AnyView? {
        guard permission == .systemAudioRecording else { return nil }
        let model = ui.model
        return AnyView(
            SystemAudioPermissionAccessory(
                test: model.systemAudioTest, openSettings: { model.openSystemAudioSettings() }))
    }
}
