import LintelKit
import LintelSpeech
import LintelUI
import SwiftUI

extension MeetingsModelCardModel {
    /// The model's state for the one-line summary.
    var choiceState: ModelChoiceRow.State {
        if progress != nil { return .downloading }
        switch location {
        case .installed: return .installed
        case .customFolder: return .customFolder
        case .customFolderUnavailable, .partial, .missing: return .notInstalled
        }
    }
}

/// "Test system audio" with its explicit "Play test signal" step and the verdict. Shared by the pane, the
/// setup step and Settings → Permissions.
struct SystemAudioTestRows: View {
    @Bindable var test: SystemAudioTestModel
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch test.state {
            case .idle:
                Button {
                    test.begin()
                } label: {
                    Text("Test System Audio", comment: "Meetings button that starts the system audio test")
                }
                .disabled(test.isBlocked)
                if test.isBlocked {
                    Text(
                        "Not available while a meeting is being recorded or processed.",
                        comment: "Meetings: why the system audio test is switched off during a meeting"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                if let outcome = test.lastOutcome {
                    verdict(outcome)
                }
            case .awaitingConfirmation:
                Text(
                    "Lintel will play a short tone through your speakers and check that it can hear it. macOS may ask you to allow System Audio Recording first. Lower the volume if you like.",
                    comment: "Meetings: explanation before the system audio test plays its signal"
                )
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button {
                        test.playSignal()
                    } label: {
                        Text("Play Test Signal", comment: "Meetings button that plays the system audio test tone")
                    }
                    .disabled(test.isBlocked)
                    Button {
                        test.cancel()
                    } label: {
                        Text("Cancel", comment: "Button that cancels the model download")
                    }
                }
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Testing…", comment: "Meetings: the system audio test is running")
                }
                .accessibilityElement(children: .combine)
            case .finished(let outcome):
                verdict(outcome)
                HStack {
                    Button {
                        test.begin()
                    } label: {
                        Text("Test Again", comment: "Meetings button that repeats the system audio test")
                    }
                    .disabled(test.isBlocked)
                    if outcome != .works {
                        Button {
                            openSettings()
                        } label: {
                            Text(
                                "Open System Audio Settings",
                                comment: "Meetings button that opens System Audio Recording privacy settings")
                        }
                    }
                }
            }
        }
        .onChange(of: test.lastOutcome) { _, outcome in
            if let outcome { AccessibilityNotification.Announcement(outcome.message).post() }
        }
    }

    private func verdict(_ outcome: SystemAudioTestModel.Outcome) -> some View {
        Label {
            Text(outcome.message).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: outcome.symbolName)
                .foregroundStyle(outcome == .works ? Color.green : Color.orange)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The test under System Audio Recording in Settings → Permissions.
struct SystemAudioPermissionAccessory: View {
    let test: SystemAudioTestModel
    let openSettings: () -> Void

    var body: some View {
        SystemAudioTestRows(test: test, openSettings: openSettings)
            .padding(.top, 4)
    }
}

/// A model's card: title, size, licence, attribution, status and the download / folder / remove actions.
struct MeetingsModelCard: View {
    @Bindable var card: MeetingsModelCardModel
    @State private var confirmingRemoval = false

    private var size: String {
        ByteCountFormatter.string(fromByteCount: Int64(card.package.totalBytes), countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent {
                Text(card.package.license)
            } label: {
                Text(card.package.title).font(.headline)
            }
            Text(card.package.attribution).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Size: \(size)", comment: "Meetings model card: download size")
                .font(.callout).foregroundStyle(.secondary)
            statusRow
            if let progress = card.progress {
                ProgressView(value: progress.fraction) {
                    Text("Downloading…", comment: "Dictation settings progress label")
                }
                .accessibilityValue(Text(progress.fraction, format: .percent.precision(.fractionLength(0))))
                Button {
                    card.cancelDownload()
                } label: {
                    Text("Cancel", comment: "Button that cancels the model download")
                }
            } else {
                actions
            }
            if let message = card.errorMessage {
                Label {
                    Text(message).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            Text("Remove \(card.package.title)?", comment: "Meetings model card: confirmation title"),
            isPresented: $confirmingRemoval, titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                Task { await card.removeModel() }
            } label: {
                Text("Remove Model", comment: "Button that deletes the downloaded speech model")
            }
        } message: {
            Text(
                "This model is shared with other Lintel features. It will be downloaded again the next time one of them needs it.",
                comment: "Meetings model card: what removing a shared model means")
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch card.location {
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
            if !card.isInstalled || card.location == .missing {
                Button {
                    card.download()
                } label: {
                    Text("Download (≈ \(size) from huggingface.co)", comment: "Button that downloads the speech model")
                }
            }
            Button {
                Task { await card.chooseFolder() }
            } label: {
                Text("Choose Folder…", comment: "Button that picks a model folder")
            }
            .disabled(card.isVerifying)
            if case .customFolder = card.location {
                Button {
                    Task { await card.useDownloadedModel() }
                } label: {
                    Text("Use Downloaded Model", comment: "Button that stops using the chosen model folder")
                }
            }
            if case .installed = card.location {
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Text("Remove Model", comment: "Button that deletes the downloaded speech model")
                }
                .disabled(card.isInUse)
                .accessibilityHint(
                    card.isInUse
                        ? Text(MeetingsModelMessages.inUse)
                        : Text(
                            "Asks before removing the model",
                            comment: "Accessibility hint of the button that removes a model"))
            }
        }
        if card.isInUse, case .installed = card.location {
            Text(MeetingsModelMessages.inUse)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if card.isVerifying {
            ProgressView().controlSize(.small)
        }
    }
}

/// The `meetings.setup` step: microphone, system audio with its test, and the models. Every part can be
/// skipped, and the whole step too.
struct MeetingsSetupView: View {
    @Bindable var model: MeetingsSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                "Record meetings and get a transcript with the speakers told apart. Everything runs on this Mac and nothing is uploaded.",
                comment: "Meetings onboarding text"
            )
            .fixedSize(horizontal: false, vertical: true)

            part(
                symbol: "mic", done: model.setupProgress.isDone(.microphone),
                text: Text(
                    "Allow the microphone. Lintel listens only while you record a meeting.",
                    comment: "Meetings onboarding step")
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

            part(
                symbol: "speaker.wave.2", done: model.setupProgress.isDone(.systemAudio),
                text: Text(
                    "Check that Lintel can hear the other side of a call. Nothing is asked until you press the button.",
                    comment: "Meetings onboarding step")
            ) {
                SystemAudioTestRows(test: model.systemAudioTest, openSettings: { model.openSystemAudioSettings() })
            }

            part(
                symbol: "arrow.down.circle", done: model.setupProgress.isDone(.models),
                text: Text(
                    "Get the speech model and the speaker model, or point to ones you already have.",
                    comment: "Meetings onboarding step")
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    MeetingsModelCard(card: model.speech)
                    MeetingsModelCard(card: model.diarization)
                }
            }

            // Optional and never counted in the checkmarks: notes are off until the user turns them on.
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        "Optional: let a model on this Mac write notes after each meeting. It is a large download that starts only when you press the button.",
                        comment: "Meetings onboarding step about the notes model"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    NotesSettingsRows(model: model.notes, showsTryIt: false)
                }
            } icon: {
                Image(systemName: "text.badge.checkmark").accessibilityHidden(true)
            }

            MeetingsSuggestionsSetupPart(model: model)
        }
        .task { await model.refresh() }
    }

    private func part<Action: View>(
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

/// The words of the destructive actions in Settings → Meetings.
enum MeetingsConfirmations {
    static func olderMeetings(count: Int) -> DestructiveConfirmation {
        DestructiveConfirmation(
            prompt: LocalizedStringResource(
                "Delete older meetings?", comment: "Meetings settings confirmation title of a shorter retention"),
            detail: LocalizedStringResource(
                "\(count) meetings are older than the new limit and are deleted now. This can’t be undone.",
                comment: "Meetings settings confirmation text of a shorter retention in the main window"),
            confirmTitle: LocalizedStringResource(
                "Delete Older Meetings", comment: "Meetings settings confirmation button"))
    }

    static let clearLibrary = DestructiveConfirmation(
        prompt: LocalizedStringResource("Delete all meetings?", comment: "Meetings settings confirmation title"),
        detail: LocalizedStringResource(
            "Every transcript, note and recording is deleted. A meeting that is being recorded is kept. This can’t be undone.",
            comment: "Meetings settings confirmation text of Clear Library in the main window"),
        confirmTitle: LocalizedStringResource("Delete All Meetings", comment: "Meetings settings confirmation button"))

    static let deleteRecordings = DestructiveConfirmation(
        prompt: LocalizedStringResource(
            "Delete temporary recordings?", comment: "Meetings settings confirmation title"),
        detail: LocalizedStringResource(
            "The audio of interrupted meetings is deleted, so they can no longer be finished. Their transcripts stay.",
            comment: "Meetings settings confirmation text of Delete Temporary Recordings"),
        confirmTitle: LocalizedStringResource("Delete Recordings", comment: "Meetings settings confirmation button"))
}
