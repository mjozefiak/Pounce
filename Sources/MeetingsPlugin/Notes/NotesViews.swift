import LintelSpeech
import SwiftUI

/// The `meetings.setup` step's notes rows: the switch and the built-in model with its download and removal.
struct NotesSettingsRows: View {
    @Bindable var model: NotesSettingsModel

    private func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    var body: some View {
        Toggle(isOn: $model.enabled) {
            Text("Write notes after each meeting", comment: "Meetings settings toggle of automatic notes")
        }
        Picker(selection: Binding(get: { model.model.id }, set: { id in Task { await model.choose(id) } })) {
            ForEach(model.models) { entry in
                Text(entry.package.title).tag(entry.id)
            }
        } label: {
            Text("Model", comment: "Dictation settings label of the formatting model")
        }
        Text(
            "Download \(bytes(model.model.package.totalBytes)), about \(bytes(model.model.residentBytes)) of memory while loaded. \(model.model.package.license) licence.",
            comment: "Dictation settings size and memory of the built-in model"
        )
        .font(.callout).foregroundStyle(.secondary)
        if model.wasReplaced {
            Label {
                Text(
                    "The model you chose does not fit this Mac, so \(model.model.package.title) is used.",
                    comment: "Meetings settings: the stored notes model is replaced by the default one"
                )
                .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").accessibilityHidden(true)
            }
            .foregroundStyle(.secondary)
        }
        modelRow
        if let message = model.errorMessage {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            }
            .foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var modelRow: some View {
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
        } else if model.isInstalled {
            LabeledContent {
                Button(role: .destructive) {
                    Task { await model.remove() }
                } label: {
                    Text("Remove", comment: "Button that deletes the downloaded model")
                }
                .disabled(model.isInUse)
                .accessibilityHint(model.isInUse ? Text(NotesMessages.modelInUse) : Text(verbatim: ""))
            } label: {
                Label {
                    Text("Downloaded", comment: "Dictation model status")
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityHidden(true)
                }
            }
        } else {
            LabeledContent {
                Button {
                    model.download()
                } label: {
                    Text(
                        "Download (≈ \(bytes(model.model.package.totalBytes)))",
                        comment: "Button that downloads the built-in formatting model")
                }
            } label: {
                Label {
                    Text("Not downloaded", comment: "Dictation model status")
                } icon: {
                    Image(systemName: "arrow.down.circle").accessibilityHidden(true)
                }
            }
        }
    }
}
