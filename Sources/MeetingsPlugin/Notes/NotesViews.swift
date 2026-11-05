import LintelSpeech
import SwiftUI

/// Settings → Meetings → Notes: the switch, the built-in model and "Try it on an example". Shared by the pane
/// and the `meetings.setup` step.
struct NotesSettingsRows: View {
    @Bindable var model: NotesSettingsModel
    /// "Try it on an example" follows the rows; the setup step keeps it out.
    var showsTryIt = true

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
        if showsTryIt { tryIt }
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

    @ViewBuilder private var tryIt: some View {
        LabeledContent {
            Button {
                model.tryIt()
            } label: {
                Text("Try it on an example", comment: "Meetings settings button that writes notes for a sample meeting")
            }
            .disabled(!model.isInstalled || model.tryState == .running)
        } label: {
            Text("Example", comment: "Meetings settings label of the notes example")
        }
        switch model.tryState {
        case .idle:
            EmptyView()
        case .running:
            HStack {
                ProgressView().controlSize(.small)
                Text("Writing notes…", comment: "Meeting window banner while the notes are being written")
            }
            .accessibilityElement(children: .combine)
        case .result(let notes):
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    "Notes for a made-up meeting. Nothing was saved.",
                    comment: "Meetings settings: caption above the example notes"
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(verbatim: notes).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        case .failed:
            Label {
                Text(
                    "The example did not work. Try again in a moment.",
                    comment: "Meetings settings: the notes example failed")
            } icon: {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            }
            .foregroundStyle(.orange)
        case .modelMissing:
            Text("Download the model first.", comment: "Meetings settings: the notes example needs the model")
                .foregroundStyle(.secondary)
        }
    }
}
