import LintelKit
import LintelSpeech
import LintelUI
import SwiftUI

/// Settings → Meetings in the old Settings window (`settingsHostStyle == .legacyWindow`), unchanged since step
/// 3.3: the model cards (speech, speakers, notes), the microphone rows and the in-body privacy messages. The notes
/// (Phase 2) and the meeting suggestions (Phase 3, `MeetingsSuggestionsSection`) have their own sections. The main
/// window draws `MeetingsPaneContent` instead (step 5.2). Deleted with the old window in step 6.3b.
struct LegacyMeetingsSettingsPane: View {
    @Bindable var model: MeetingsSettingsModel
    /// The shortcut recorder, or `nil` while the `meetings.record` command does not exist.
    let recorder: AnyView?
    /// `false` while the plugin is off (the main window shows the pane dimmed): the pane then reads no model
    /// folder or device list (`settingsPane()` must not start work while inactive).
    var isActive = true
    /// `PluginContext.openModels`: the Models pane on the package's row.
    var openModels: (String?) -> Void = { _ in }
    @Environment(\.settingsHostStyle) private var hostStyle
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
                MeetingsInputDevicePicker(model: model)
                if hostStyle == .legacyWindow {
                    MeetingsMicrophoneRows(model: model)
                }
                Toggle(isOn: $model.voiceProcessing) {
                    Text("Reduce echo from the speakers", comment: "Meetings settings toggle of voice processing")
                }
                SystemAudioTestRows(test: model.systemAudioTest, openSettings: { model.openSystemAudioSettings() })
            } header: {
                Text("Audio", comment: "Meetings settings section title")
            } footer: {
                Text(
                    "Lintel records your microphone and what the other side says, only while you record a meeting. Echo reduction can lower the volume of other apps, so it is off by default.",
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
                if hostStyle == .legacyWindow {
                    MeetingsModelCard(card: model.speech)
                    MeetingsModelCard(card: model.diarization)
                } else {
                    ModelChoiceRow(title: model.speech.package.title, state: model.speech.choiceState) {
                        openModels(model.speech.package.id)
                    }
                    ModelChoiceRow(title: model.diarization.package.title, state: model.diarization.choiceState) {
                        openModels(model.diarization.package.id)
                    }
                }
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
                NotesSettingsRows(model: model.notes)
            } header: {
                Text("Notes", comment: "Meetings settings section title of the notes")
            } footer: {
                Text(
                    "After a meeting, a model that runs on this Mac writes a summary, decisions, action items and open questions in the background. Every point must quote the recording, and points without a matching quote are left out. The notes can still contain mistakes. Nothing is sent anywhere.",
                    comment: "Meetings settings footer under the notes"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            MeetingsSuggestionsSection(model: model)

            Section {
                Toggle(isOn: $model.consentReminder) {
                    Text("Remind me to tell people I am recording", comment: "Meetings settings toggle")
                }
                Picker(selection: Binding(get: { model.retentionDays }, set: { model.selectRetention($0) })) {
                    ForEach(model.retentionChoices(), id: \.self) { days in
                        Text(MeetingsSettingsPane.retentionTitle(days)).tag(days)
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
        .task(id: isActive) {
            guard isActive else { return }
            await model.refresh()
        }
        .onChange(of: model.privacyMessage) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { model.pendingRetention != nil }, set: { if !$0 { model.cancelRetention() } }),
            MeetingsConfirmations.olderMeetings(count: model.pendingRetention?.affected ?? 0)
        ) {
            model.confirmRetention()
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { confirmation == .clearLibrary }, set: { if !$0 { confirmation = nil } }),
            MeetingsConfirmations.clearLibrary
        ) {
            model.clearLibrary()
        }
        .destructiveConfirmation(
            isPresented: Binding(
                get: { confirmation == .deleteRecordings }, set: { if !$0 { confirmation = nil } }),
            MeetingsConfirmations.deleteRecordings
        ) {
            model.deleteTemporaryRecordings()
        }
    }
}
