import PounceKit
import PounceSpeech
import SwiftUI

/// Settings → Meetings. The notes (a built-in model card, Phase 2) and the meeting suggestions (Phase 3) get
/// their sections here when those steps exist; nothing is shown for them now.
struct MeetingsSettingsPane: View {
    @Bindable var model: MeetingsSettingsModel
    /// The shortcut recorder, or `nil` while the `meetings.record` command does not exist.
    let recorder: AnyView?
    @State private var confirmation: PrivacyConfirmation?

    private enum PrivacyConfirmation: Identifiable {
        case clearLibrary
        case deleteRecordings
        var id: Self { self }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if let recorder {
                        recorder
                    } else {
                        Text("Not available yet", comment: "Meetings settings: the shortcut row without a command")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    Text("Record meeting", comment: "Meetings settings label of the record shortcut")
                }
                .disabled(recorder == nil)
            } header: {
                Text("Shortcut", comment: "Settings section title")
            } footer: {
                Text(
                    "Press to start recording a meeting and press again to stop.",
                    comment: "Meetings settings footer under the shortcut"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                MeetingsMicrophoneRows(model: model)
                Toggle(isOn: $model.voiceProcessing) {
                    Text("Reduce echo from the speakers", comment: "Meetings settings toggle of voice processing")
                }
                SystemAudioTestRows(test: model.systemAudioTest, openSettings: { model.openSystemAudioSettings() })
            } header: {
                Text("Audio", comment: "Meetings settings section title")
            } footer: {
                Text(
                    "Pounce records your microphone and what the other side says, only while you record a meeting. Echo reduction can lower the volume of other apps, so it is off by default.",
                    comment: "Meetings settings footer under the audio section"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: Binding(get: { model.speechPackageID }, set: { model.selectSpeechModel($0) })) {
                    ForEach(model.speechPackages) { package in
                        Text(package.title).tag(package.id)
                    }
                } label: {
                    Text("Engine", comment: "Dictation settings label of the speech engine choice")
                }
                if model.usesPinnedLanguage {
                    Picker(selection: $model.speechLanguage) {
                        Text("Polish", comment: "Dictation language choice").tag("pl")
                        Text("English", comment: "Dictation language choice").tag("en")
                    } label: {
                        Text("Language", comment: "Dictation settings label of the pinned language")
                    }
                }
                MeetingsModelCard(card: model.speech)
                MeetingsModelCard(card: model.diarization)
            } header: {
                Text("Models", comment: "Meetings settings section title")
            } footer: {
                Text(
                    "The models run on this Mac. Audio is never sent anywhere. The speech model is shared with dictation.",
                    comment: "Meetings settings footer under the models"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $model.consentReminder) {
                    Text("Remind me to tell people I am recording", comment: "Meetings settings toggle")
                }
                Picker(selection: Binding(get: { model.retentionDays }, set: { model.selectRetention($0) })) {
                    ForEach(model.retentionChoices(), id: \.self) { days in
                        Text(Self.retentionTitle(days)).tag(days)
                    }
                } label: {
                    Text("Keep meetings for", comment: "Meetings settings label of the retention choice")
                }
                Button(role: .destructive) {
                    confirmation = .clearLibrary
                } label: {
                    Text("Clear Library…", comment: "Meetings settings button that deletes all meetings")
                }
                .disabled(!model.canChangeLibrary)
                Button(role: .destructive) {
                    confirmation = .deleteRecordings
                } label: {
                    Text(
                        "Delete Temporary Recordings…",
                        comment: "Meetings settings button that deletes the audio of interrupted meetings")
                }
                .disabled(!model.canChangeLibrary)
                if let message = model.privacyMessage {
                    Label {
                        Text(message).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: model.privacyFailed ? "exclamationmark.triangle" : "checkmark.circle")
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(model.privacyFailed ? Color.orange : Color.secondary)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Privacy", comment: "Dictation settings section title")
            } footer: {
                Text(
                    "Meetings older than the period you choose are deleted, together with their transcripts and notes.",
                    comment: "Meetings settings footer under the retention choice"
                )
                .font(.callout).foregroundStyle(.secondary)
                Text(
                    "Recordings are encrypted and deleted once a meeting is processed. A deleted file is not overwritten: on an SSD or in a backup a copy may remain for a while, though it is encrypted and unreadable without the key. Erase Data removes the key too.",
                    comment: "Meetings settings footer about deleted data on an SSD"
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await model.refresh() }
        .onChange(of: model.privacyMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .confirmationDialog(
            Text("Delete older meetings?", comment: "Meetings settings confirmation title of a shorter retention"),
            isPresented: Binding(
                get: { model.pendingRetention != nil }, set: { if !$0 { model.cancelRetention() } }),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                model.confirmRetention()
            } label: {
                Text("Delete Older Meetings", comment: "Meetings settings confirmation button")
            }
        } message: {
            Text(
                "\(model.pendingRetention?.affected ?? 0) meetings are older than the new limit and are deleted now. This cannot be undone.",
                comment: "Meetings settings confirmation text of a shorter retention")
        }
        .confirmationDialog(
            Text("Delete all meetings?", comment: "Meetings settings confirmation title"),
            isPresented: Binding(
                get: { confirmation == .clearLibrary }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                model.clearLibrary()
            } label: {
                Text("Delete All Meetings", comment: "Meetings settings confirmation button")
            }
        } message: {
            Text(
                "Every transcript, note and recording is deleted. A meeting that is being recorded is kept. This cannot be undone.",
                comment: "Meetings settings confirmation text of Clear Library")
        }
        .confirmationDialog(
            Text("Delete temporary recordings?", comment: "Meetings settings confirmation title"),
            isPresented: Binding(
                get: { confirmation == .deleteRecordings }, set: { if !$0 { confirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                model.deleteTemporaryRecordings()
            } label: {
                Text("Delete Recordings", comment: "Meetings settings confirmation button")
            }
        } message: {
            Text(
                "The audio of interrupted meetings is deleted, so they can no longer be finished. Their transcripts stay.",
                comment: "Meetings settings confirmation text of Delete Temporary Recordings")
        }
    }

    static func retentionTitle(_ days: Int) -> String {
        days == 0
            ? String(localized: "Until I delete them", comment: "Meetings settings retention choice without a limit")
            : String(localized: "\(days) days", comment: "Meetings settings retention choice")
    }
}

/// Input device, microphone permission and the Allow / Open Settings buttons.
struct MeetingsMicrophoneRows: View {
    @Bindable var model: MeetingsSettingsModel

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
                if let outcome = test.lastOutcome {
                    verdict(outcome)
                }
            case .awaitingConfirmation:
                Text(
                    "Pounce will play a short tone through your speakers and check that it can hear it. macOS may ask you to allow System Audio Recording first. Lower the volume if you like.",
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
                "This model is shared with other Pounce features. It will be downloaded again the next time one of them needs it.",
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
                    "Allow the microphone. Pounce listens only while you record a meeting.",
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
                    "Check that Pounce can hear the other side of a call. Nothing is asked until you press the button.",
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
