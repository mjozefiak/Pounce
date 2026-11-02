import PounceKit
import SwiftUI

/// Settings → Dictation.
struct DictationSettingsPane: View {
    @Bindable var model: DictationSettingsModel
    let recorder: AnyView

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    recorder
                } label: {
                    Text("Dictate", comment: "Menu item and command that starts dictation")
                }
            } header: {
                Text("Shortcut", comment: "Settings section title")
            } footer: {
                Text(
                    "Press to start and press again to stop. Or hold the keys while you talk. Esc cancels.",
                    comment: "Dictation settings footer under the shortcut"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                SpeechModelCard(model: model)
            } header: {
                Text("Speech model", comment: "Dictation settings section title")
            } footer: {
                Text(
                    "The model runs on this Mac. Audio is never sent anywhere and never saved.",
                    comment: "Dictation settings footer under the speech model"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                MicrophoneRows(model: model)
            } header: {
                Text("Microphone", comment: "Dictation settings section title")
            }

            Section {
                Toggle(isOn: $model.restoresClipboard) {
                    Text("Restore the clipboard after pasting", comment: "Dictation settings toggle")
                }
            } header: {
                Text("Privacy", comment: "Dictation settings section title")
            } footer: {
                Text(
                    "The text is pasted through the clipboard. Pounce puts back what was there a second later, unless it was a password or you copied something else meanwhile.",
                    comment: "Dictation settings footer under the clipboard restore toggle"
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
    }
}

struct SpeechModelCard: View {
    @Bindable var model: DictationSettingsModel

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(model.package.totalBytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(model.package.license)
            } label: {
                Text(model.package.title).font(.headline)
            }
            Text(model.package.attribution).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            statusRow
            if let progress = model.progress {
                ProgressView(value: progress.fraction) {
                    Text("Downloading…", comment: "Dictation settings progress label")
                }
                .accessibilityValue(Text(progress.fraction, format: .percent.precision(.fractionLength(0))))
                Button {
                    model.cancelDownload()
                } label: {
                    Text("Cancel", comment: "Button that cancels the model download")
                }
            } else {
                actions
            }
            if let message = model.errorMessage {
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch model.location {
        case .installed:
            Label {
                Text("Downloaded", comment: "Dictation model status")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
            }
        case .customFolder(let url):
            Label {
                Text("Using the folder \(url.path)", comment: "Dictation model status with the folder path")
            } icon: {
                Image(systemName: "folder.fill").accessibilityHidden(true)
            }
        case .customFolderUnavailable(let url):
            Label {
                Text("Folder unavailable: \(url.path)", comment: "Dictation model status when the folder is gone")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            }
        case .partial:
            Label {
                Text("Download interrupted. It continues where it stopped.", comment: "Dictation model status")
            } icon: {
                Image(systemName: "arrow.down.circle").accessibilityHidden(true)
            }
        case .missing:
            Label {
                Text("Not downloaded", comment: "Dictation model status")
            } icon: {
                Image(systemName: "arrow.down.circle").accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if !model.isInstalled || model.location == .missing {
                Button {
                    model.download()
                } label: {
                    Text("Download (≈ \(size) from huggingface.co)", comment: "Button that downloads the speech model")
                }
            }
            Button {
                model.chooseFolder()
            } label: {
                Text("Choose Folder…", comment: "Button that picks a model folder")
            }
            .disabled(model.isVerifying)
            if case .customFolder = model.location {
                Button {
                    model.useDownloadedModel()
                } label: {
                    Text("Use Downloaded Model", comment: "Button that stops using the chosen model folder")
                }
            }
            if case .installed = model.location {
                Button(role: .destructive) {
                    model.removeModel()
                } label: {
                    Text("Remove Model", comment: "Button that deletes the downloaded speech model")
                }
            }
        }
        if model.isVerifying {
            ProgressView().controlSize(.small)
        }
    }
}

struct MicrophoneRows: View {
    @Bindable var model: DictationSettingsModel

    var body: some View {
        Picker(selection: $model.inputDevice) {
            Text("System default", comment: "Dictation input device choice that follows the system").tag(String?.none)
            ForEach(model.devices) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        } label: {
            Text("Input device", comment: "Dictation settings label")
        }
        HStack {
            switch model.microphone {
            case .granted:
                Label {
                    Text("Microphone allowed", comment: "Dictation microphone status")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
                Spacer()
                if let level = model.level {
                    ProgressView(value: Double(level)).frame(width: 80)
                        .accessibilityLabel(Text("Input level", comment: "Accessibility label of the level meter"))
                } else {
                    Button {
                        model.testMicrophone()
                    } label: {
                        Text("Test", comment: "Button that shows the microphone level for a moment")
                    }
                }
            case .notDetermined:
                Text("Microphone not asked yet", comment: "Dictation microphone status")
                Spacer()
                Button {
                    model.requestMicrophone()
                } label: {
                    Text("Allow Microphone", comment: "Button that asks for microphone access")
                }
            case .denied:
                Label {
                    Text("Microphone not allowed", comment: "Dictation HUD when microphone access is denied")
                } icon: {
                    Image(systemName: "mic.slash").foregroundStyle(.orange).accessibilityHidden(true)
                }
                Spacer()
                Button {
                    model.openMicrophoneSettings()
                } label: {
                    Text("Open Microphone Settings", comment: "Button that opens microphone privacy settings")
                }
            }
        }
    }
}

/// The welcome screen's setup step: microphone, model, Accessibility. Every part can be skipped.
struct DictationSetupView: View {
    @Bindable var model: DictationSettingsModel
    let accessibilityAllowed: () -> Bool
    @State private var accessibility = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Dictate in any app: press the shortcut, talk, and Pounce types the text where you are. The speech model runs on this Mac.",
                comment: "Dictation onboarding text"
            )
            .fixedSize(horizontal: false, vertical: true)

            step(
                symbol: "mic", done: model.microphone == .granted,
                text: Text(
                    "Allow the microphone. Pounce listens only while you dictate.", comment: "Dictation onboarding step"
                )
            ) {
                if model.microphone == .denied {
                    Button {
                        model.openMicrophoneSettings()
                    } label: {
                        Text("Open Microphone Settings", comment: "Button that opens microphone privacy settings")
                    }
                } else {
                    Button {
                        model.requestMicrophone()
                    } label: {
                        Text("Allow Microphone", comment: "Button that asks for microphone access")
                    }
                }
            }

            step(
                symbol: "arrow.down.circle", done: model.isInstalled,
                text: Text(
                    "Get the speech model (about 0.7 GB), or point to one you already have.",
                    comment: "Dictation onboarding step")
            ) {
                SpeechModelCard(model: model)
            }

            step(
                symbol: "keyboard", done: accessibility,
                text: Text(
                    "Allow Accessibility so Pounce can paste for you. Without it, the text is only copied.",
                    comment: "Dictation onboarding step")
            ) {
                Button {
                    model.openAccessibilitySettings()
                } label: {
                    Text("Open Accessibility Settings", comment: "Button that opens Accessibility privacy settings")
                }
            }
        }
        .task {
            await model.refresh()
            accessibility = accessibilityAllowed()
        }
    }

    private func step<Action: View>(
        symbol: String, done: Bool, text: Text, @ViewBuilder action: () -> Action
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                text.fixedSize(horizontal: false, vertical: true)
                if done {
                    Label {
                        Text("Done", comment: "Onboarding status of a finished step")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                    }
                } else {
                    action()
                }
            }
        } icon: {
            Image(systemName: symbol).accessibilityHidden(true)
        }
    }
}
