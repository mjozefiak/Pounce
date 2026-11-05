import LintelKit
import LintelUI
import SwiftUI

/// Settings → Meetings. The main window draws `MeetingsPaneContent` on the `SettingsPane` template (prototype
/// `set-meetings`, spec step 5.2); the old window keeps `LegacyMeetingsSettingsPane` with its model cards,
/// microphone rows and notes card. The main window's banner is the host's, from `MeetingsPlugin.settingsStatus`.
struct MeetingsSettingsPane: View {
    @Bindable var model: MeetingsSettingsModel
    /// The shortcut recorder, or `nil` while the `meetings.record` command does not exist.
    let recorder: AnyView?
    /// `false` while the plugin is off (the main window shows the pane dimmed): the pane then reads no model
    /// folder or device list (`settingsPane()` must not start work while inactive).
    var isActive = true
    /// `PluginContext.openModels`: the Models pane on the package's row.
    var openModels: (String?) -> Void = { _ in }
    @Environment(\.settingsHostStyle) private var hostStyle

    var body: some View {
        if hostStyle == .legacyWindow {
            LegacyMeetingsSettingsPane(model: model, recorder: recorder, isActive: isActive, openModels: openModels)
        } else {
            MeetingsPaneContent(model: model, recorder: recorder, isActive: isActive, openModels: openModels)
        }
    }

    static func retentionTitle(_ days: Int) -> String {
        days == 0
            ? String(localized: "Until I delete them", comment: "Meetings settings retention choice without a limit")
            : String(localized: "\(days) days", comment: "Meetings settings retention choice")
    }
}

/// The main window's Meetings pane (prototype `set-meetings`): Basics (Record meeting, Write notes and, while it
/// is on, the notes model, Speech model with its one-line summary, Keep meetings for), a collapsed Advanced
/// (Input device, echo, meeting suggestions, Test System Audio) and Privacy and data (the reminder, Clear
/// Library…, Delete Temporary Recordings…). The models live in Models, the microphone in Permissions; their
/// state is the host's banner.
struct MeetingsPaneContent: View {
    @Bindable var model: MeetingsSettingsModel
    let recorder: AnyView?
    var isActive = true
    var openModels: (String?) -> Void = { _ in }

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmation: PrivacyConfirmation?
    @State private var newApp = ""

    private enum PrivacyConfirmation: Identifiable {
        case clearLibrary
        case deleteRecordings
        var id: Self { self }
    }

    var body: some View {
        SettingsPane(
            dataTitle: LocalizedStringResource(
                "Privacy and data", comment: "Settings → Meetings section title: the reminder and the library")
        ) {
            Section {
                basics
            } header: {
                Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                    .font(textSize.font(.body, weight: .semibold))
            }
        } advanced: {
            advanced
        } data: {
            privacyRows
        }
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

    // MARK: Basics

    @ViewBuilder private var basics: some View {
        LabeledContent {
            if let recorder {
                recorder
            } else {
                Text("Not available yet", comment: "Meetings settings: the shortcut row without a command")
                    .font(textSize.font(.body))
                    .foregroundStyle(.secondary)
            }
        } label: {
            label(
                Text("Record meeting", comment: "Meetings settings label of the record shortcut"),
                help: Text(
                    "Press to start and again to stop.",
                    comment: "Settings → Meetings: help under the Record meeting shortcut"))
        }
        .disabled(recorder == nil)
        Toggle(isOn: Binding(get: { model.notes.enabled }, set: { model.notes.enabled = $0 })) {
            label(
                Text("Write notes after each meeting", comment: "Meetings settings toggle of automatic notes"),
                help: Text(
                    "Summary, decisions, tasks. Needs the notes model.",
                    comment: "Settings → Meetings: help under Write notes after each meeting"))
        }
        .toggleStyle(.switch)
        if model.notes.enabled {
            notesModelRow
        }
        LabeledContent {
            Picker(selection: Binding(get: { model.speechPackageID }, set: { model.selectSpeechModel($0) })) {
                ForEach(model.speechPackages) { package in
                    Text(package.title).font(textSize.font(.body)).tag(package.id)
                }
            } label: {
                Text("Speech model", comment: "Dictation settings section title")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(textSize.font(.body))
            .fixedSize()
        } label: {
            Text("Speech model", comment: "Dictation settings section title")
                .font(textSize.font(.body))
            ModelChoiceRow(title: model.speech.package.title, state: model.speech.choiceState, style: .help) {
                openModels(model.speech.package.id)
            }
        }
        if model.usesPinnedLanguage {
            // Whisper listens for one language; Parakeet needs no choice.
            MenuPicker(selection: $model.speechLanguage) {
                Text("Polish", comment: "Dictation language choice").font(textSize.font(.body)).tag("pl")
                Text("English", comment: "Dictation language choice").font(textSize.font(.body)).tag("en")
            } label: {
                label(
                    Text("Language", comment: "Dictation settings label of the pinned language"),
                    help: Text(
                        "Whisper listens for the language you choose.",
                        comment: "Settings → Dictation: help under the language of the Whisper model"))
            }
        }
        MenuPicker(selection: Binding(get: { model.retentionDays }, set: { model.selectRetention($0) })) {
            ForEach(model.retentionChoices(), id: \.self) { days in
                Text(MeetingsSettingsPane.retentionTitle(days)).font(textSize.font(.body)).tag(days)
            }
        } label: {
            Text("Keep meetings for", comment: "Meetings settings label of the retention choice")
                .font(textSize.font(.body))
        }
    }

    /// The notes model: the choice here, download and removal in Models (the old window's notes card).
    @ViewBuilder private var notesModelRow: some View {
        let notes = model.notes
        MenuPicker(
            selection: Binding(get: { notes.model.id }, set: { id in Task { await notes.choose(id) } }),
            title: Text("Notes model", comment: "Settings → Meetings label of the model that writes the notes")
        ) {
            ForEach(notes.models) { entry in
                Text(entry.package.title).font(textSize.font(.body)).tag(entry.id)
            }
        } label: {
            Text("Notes model", comment: "Settings → Meetings label of the model that writes the notes")
                .font(textSize.font(.body))
            ModelChoiceRow(title: notes.model.package.title, state: notes.choiceState, style: .help) {
                openModels(notes.model.id)
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        MenuPicker(selection: $model.inputDevice) {
            Text("System default", comment: "Dictation input device choice that follows the system")
                .font(textSize.font(.body)).tag(String?.none)
            ForEach(model.devices) { device in
                Text(device.name).font(textSize.font(.body)).tag(Optional(device.uid))
            }
        } label: {
            Text("Input device", comment: "Dictation settings label")
                .font(textSize.font(.body))
        }
        Toggle(isOn: $model.voiceProcessing) {
            label(
                Text("Reduce echo from speakers", comment: "Settings → Meetings switch of voice processing"),
                help: Text(
                    "Can lower other apps’ volume.", comment: "Settings → Meetings: help under Reduce echo"))
        }
        .toggleStyle(.switch)
        Toggle(isOn: $model.suggestMeetings) {
            Text("Suggest recording when a meeting starts", comment: "Meetings settings toggle of suggestions")
                .font(textSize.font(.body))
        }
        .toggleStyle(.switch)
        if model.suggestMeetings {
            suggestionRows
        }
        SystemAudioTestRow(test: model.systemAudioTest, openSettings: { model.openSystemAudioSettings() })
    }

    /// While suggestions are on: whether they work here, the apps the user muted and the apps they added.
    @ViewBuilder private var suggestionRows: some View {
        if model.suggestionStatus == .unavailable {
            Text(
                "Not available on this Mac: macOS does not report which apps use the microphone here.",
                comment: "Meetings settings: the process audio API is unavailable"
            )
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.statusAttention)
        } else if model.suggestionStatus == .noData {
            Text(MeetingsSuggestionsSection.noDataMessage)
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.statusAttention)
        }
        if !model.mutedApps.isEmpty {
            secondary(Text("Apps you muted", comment: "Meetings settings: list of apps with suggestions turned off"))
            ForEach(model.mutedApps) { app in
                appRow(app) {
                    Button {
                        model.unmute(app.id)
                    } label: {
                        Text("Ask again", comment: "Button that unmutes an app").font(textSize.font(.body))
                    }
                }
            }
        }
        secondary(
            Text("Other apps that count as meetings", comment: "Meetings settings: list of apps added by the user"))
        ForEach(model.extraApps) { app in
            appRow(app) {
                Button {
                    model.removeExtraApp(app.id)
                } label: {
                    Text("Remove", comment: "Button that removes an added app").font(textSize.font(.body))
                }
            }
        }
        LabeledContent {
            Button(action: addApp) {
                Text("Add", comment: "Button that adds an app to the meeting suggestions")
                    .font(textSize.font(.body))
            }
            .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
        } label: {
            TextField(
                text: $newApp,
                prompt: Text("e.g. com.google.Chrome", comment: "Placeholder of the bundle ID field")
            ) {
                Text("Bundle ID", comment: "Label of the field that adds an app to the meeting suggestions")
            }
            .labelsHidden()
            .font(textSize.font(.body))
            .onSubmit(addApp)
            if let error = model.extraAppError {
                Text(MeetingsSuggestionsSection.message(error))
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.statusError)
            }
        }
    }

    private func addApp() {
        if model.addExtraApp(newApp) { newApp = "" }
    }

    private func appRow<Action: View>(_ app: SuggestionApp, @ViewBuilder action: () -> Action) -> some View {
        LabeledContent {
            action()
        } label: {
            Text(app.name).font(textSize.font(.body))
            if app.name != app.id {
                Text(verbatim: app.id).font(textSize.font(.callout)).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func secondary(_ text: Text) -> some View {
        text.font(textSize.font(.callout)).foregroundStyle(.secondary)
    }

    // MARK: Privacy and data

    @ViewBuilder private var privacyRows: some View {
        Toggle(isOn: $model.consentReminder) {
            Text("Remind me to say I am recording", comment: "Settings → Meetings switch of the consent reminder")
                .font(textSize.font(.body))
        }
        .toggleStyle(.switch)
        LabeledContent {
            Button(role: .destructive) {
                confirmation = .clearLibrary
            } label: {
                Text("Clear Library…", comment: "Meetings settings button that deletes all meetings")
                    .font(textSize.font(.body))
            }
            .disabled(!model.canChangeLibrary)
        } label: {
            Text("Library", comment: "Settings → Meetings row of the meeting library")
                .font(textSize.font(.body))
        }
        LabeledContent {
            Button(role: .destructive) {
                confirmation = .deleteRecordings
            } label: {
                Text(
                    "Delete Temporary Recordings…",
                    comment: "Meetings settings button that deletes the audio of interrupted meetings"
                )
                .font(textSize.font(.body))
            }
            .disabled(!model.canChangeLibrary)
        } label: {
            label(
                Text("Temporary recordings", comment: "Settings → Meetings row of the audio of interrupted meetings"),
                help: Text(
                    "Audio of interrupted meetings.",
                    comment: "Settings → Meetings: help under Temporary recordings"))
        }
        if let message = model.privacyMessage {
            Text(message)
                .font(textSize.font(.callout))
                .foregroundStyle(model.privacyFailed ? LintelBrand.statusError : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A row label with its one-line help under it, as the prototype's `R(label, help, control)`.
    private func label(_ title: Text, help: Text) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(textSize.font(.body))
            help.font(textSize.font(.callout)).foregroundStyle(.secondary)
        }
    }
}

/// "Test System Audio" as one settings row (prototype: the label and a Test button). The explicit "Play Test
/// Signal" step and the verdict follow under the label; nothing is played before that second click.
struct SystemAudioTestRow: View {
    @Bindable var test: SystemAudioTestModel
    let openSettings: () -> Void
    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        LabeledContent {
            controls
        } label: {
            Text("Test System Audio", comment: "Meetings button that starts the system audio test")
                .font(textSize.font(.body))
            detail
        }
        .onChange(of: test.lastOutcome) { _, outcome in
            if let outcome { AccessibilityNotification.Announcement(outcome.message).post() }
        }
    }

    @ViewBuilder private var controls: some View {
        switch test.state {
        case .idle:
            button(Text("Test (system audio)", comment: "Settings → Meetings button that starts the system audio test"))
            {
                test.begin()
            }
            .disabled(test.isBlocked)
        case .awaitingConfirmation:
            HStack {
                button(Text("Cancel", comment: "Button that cancels the model download")) { test.cancel() }
                button(Text("Play Test Signal", comment: "Meetings button that plays the system audio test tone")) {
                    test.playSignal()
                }
                .disabled(test.isBlocked)
            }
        case .running:
            ProgressView().controlSize(.small)
        case .finished(let outcome):
            HStack {
                if outcome != .works {
                    button(
                        Text(
                            "Open System Audio Settings",
                            comment: "Meetings button that opens System Audio Recording privacy settings")
                    ) { openSettings() }
                }
                button(Text("Test Again", comment: "Meetings button that repeats the system audio test")) {
                    test.begin()
                }
                .disabled(test.isBlocked)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch test.state {
        case .idle:
            if test.isBlocked {
                secondary(
                    Text(
                        "Not available while a meeting is being recorded or processed.",
                        comment: "Meetings: why the system audio test is switched off during a meeting"))
            }
        case .awaitingConfirmation:
            secondary(
                Text(
                    "Lintel will play a short tone through your speakers and check that it can hear it. macOS may ask you to allow System Audio Recording first. Lower the volume if you like.",
                    comment: "Meetings: explanation before the system audio test plays its signal"))
        case .running:
            secondary(Text("Testing…", comment: "Meetings: the system audio test is running"))
        case .finished(let outcome):
            Text(outcome.message)
                .font(textSize.font(.callout))
                .foregroundStyle(outcome == .works ? LintelBrand.statusOk : LintelBrand.statusAttention)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func secondary(_ text: Text) -> some View {
        text.font(textSize.font(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func button(_ title: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) { title.font(textSize.font(.body)) }
    }
}

extension NotesSettingsModel {
    /// The notes model's state for the main window's one-line summary.
    var choiceState: ModelChoiceRow.State {
        if progress != nil { return .downloading }
        return isInstalled ? .installed : .notInstalled
    }
}
