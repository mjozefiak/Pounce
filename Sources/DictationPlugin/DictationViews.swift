import LintelKit
import LintelUI
import SwiftUI

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
            Text(model.package.attribution).font(.caption).foregroundStyle(LintelBrand.secondaryText)
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

extension DictationSettingsModel {
    /// The speech model's state for the one-line summary.
    var choiceState: ModelChoiceRow.State {
        if progress != nil { return .downloading }
        switch location {
        case .installed: return .installed
        case .customFolder: return .customFolder
        case .customFolderUnavailable, .partial, .missing: return .notInstalled
        }
    }
}

/// The welcome screen's setup step: microphone, model, Accessibility. Every part can be skipped.
struct DictationSetupView: View {
    @Bindable var model: DictationSettingsModel
    let accessibilityAllowed: () -> Bool
    @State private var accessibility = false

    static let text = LocalizedStringResource(
        "Dictate in any app: press the shortcut, talk, and Lintel types the text where you are. The speech model runs on this Mac.",
        comment: "Dictation onboarding text")

    var body: some View {
        // The welcome page's controls (prototype `shell-welcome-*`); the explanation is the step's `text`.
        // The microphone is asked only when Allow Microphone is clicked.
        WelcomeStepColumn {
            WelcomeStepItem(
                Text(
                    "Allow the microphone. Lintel listens only while you dictate.", comment: "Dictation onboarding step"
                ),
                isDone: model.microphone == .granted
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

            WelcomeStepItem(
                Text(
                    "Get the speech model (about 0.7 GB), or point to one you already have.",
                    comment: "Dictation onboarding step"),
                isDone: model.isInstalled
            ) {
                SpeechModelCard(model: model)
            }

            WelcomeStepItem(
                Text(
                    "Allow Accessibility so Lintel can paste for you. Without it, the text is only copied.",
                    comment: "Dictation onboarding step"),
                isDone: accessibility
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
}

extension FormattingSettingsModel {
    /// The built-in model's state for the one-line summary.
    var builtInChoiceState: ModelChoiceRow.State {
        isBuiltInInstalled ? .installed : .notInstalled
    }
}

/// Settings → Dictation → History: the Clear History question.
enum HistorySection {
    static let confirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource(
            "Clear the dictation history?", comment: "Dictation settings confirmation title"),
        detail: LocalizedStringResource(
            "This deletes every saved dictation. This can’t be undone.",
            comment: "Dictation settings confirmation text in the main window"),
        confirmTitle: LocalizedStringResource("Clear History", comment: "Dictation settings confirmation button"))
}

/// The history list when nothing is saved yet (or the history is off).
struct DictationHistoryEmptyView: View {
    let history: DictationHistory

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(LintelBrand.secondaryText)
            Text(
                history.status == .closed
                    ? String(
                        localized: "The dictation history is off. Turn it on in Settings → Dictation.",
                        comment: "Dictation history empty state when the history is off")
                    : String(
                        localized: "No dictations yet.", comment: "Dictation history empty state")
            )
            .foregroundStyle(LintelBrand.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
