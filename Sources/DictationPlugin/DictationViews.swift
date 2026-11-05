import LintelKit
import SwiftUI

/// Settings → Dictation.
struct DictationSettingsPane: View {
    @Bindable var model: DictationSettingsModel
    @Bindable var formatting: FormattingSettingsModel
    @Bindable var history: HistorySettingsModel
    let recorder: AnyView
    /// `false` while the plugin is off (the main window shows the pane dimmed): the pane then probes no
    /// server and reads no model folder (`settingsPane()` must not start work while inactive).
    var isActive = true

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
                Picker(selection: Binding(get: { model.speechModelID }, set: { model.selectSpeechModel($0) })) {
                    ForEach(model.packages) { package in
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
                    Text(
                        "Whisper does not guess the language: it listens for the one you choose. If Parakeet turns your Polish into English, switch to Whisper.",
                        comment: "Dictation settings note about the pinned language"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
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

            FormattingSection(model: formatting)

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
                    "The text is pasted through the clipboard. Lintel puts back what was there a second later, unless it was a password or you copied something else meanwhile.",
                    comment: "Dictation settings footer under the clipboard restore toggle"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            HistorySection(model: history)
        }
        .formStyle(.grouped)
        .task(id: isActive) {
            guard isActive else { return }
            await model.refresh()
            await formatting.refresh()
        }
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
                "Dictate in any app: press the shortcut, talk, and Lintel types the text where you are. The speech model runs on this Mac.",
                comment: "Dictation onboarding text"
            )
            .fixedSize(horizontal: false, vertical: true)

            step(
                symbol: "mic", done: model.microphone == .granted,
                text: Text(
                    "Allow the microphone. Lintel listens only while you dictate.", comment: "Dictation onboarding step"
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
                    "Allow Accessibility so Lintel can paste for you. Without it, the text is only copied.",
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

/// Settings → Dictation → Formatting: the optional clean-up by the user's local language model.
struct FormattingSection: View {
    @Bindable var model: FormattingSettingsModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.isCleanupOn }, set: { model.mode = $0 ? .cleanup : .raw })) {
                Text("Clean up the text with a local model", comment: "Dictation settings toggle for formatting")
            }
            if model.isCleanupOn {
                if model.offersBuiltIn {
                    Picker(selection: $model.source) {
                        Text("Built-in (Lintel)", comment: "Dictation settings choice of the built-in formatting model")
                            .tag(DictationSettings.LLMSource.builtIn)
                        Text("My server", comment: "Dictation settings choice of the user's formatting server")
                            .tag(DictationSettings.LLMSource.server)
                    } label: {
                        Text("Run on", comment: "Dictation settings label of the formatting source")
                    }
                }
                if model.isBuiltIn {
                    BuiltInModelRows(model: model)
                } else {
                    serverRows
                }
                if model.hasTarget {
                    tryRows
                }
            }
        } header: {
            Text("Formatting", comment: "Dictation settings section title")
        } footer: {
            if model.isBuiltIn {
                Text(
                    "The model runs inside Lintel on this Mac. Nothing is sent anywhere. It loads while you talk and is freed after a while. If it is not ready in time, the raw text is pasted.",
                    comment: "Dictation settings footer under the built-in formatting model"
                )
                .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(
                    "Lintel sends the text only to a server on this Mac (Ollama, LM Studio, llama-server). The server may keep prompts in its own log. If it does not answer, the raw text is pasted.",
                    comment: "Dictation settings footer under the formatting toggle"
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var serverRows: some View {
        if model.endpoints.isEmpty {
            LabeledContent {
                if model.isProbing {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Text(
                    model.isProbing ? "Looking for a server…" : "No server found on this Mac",
                    comment: "Dictation settings status of the formatting server")
            }
        } else {
            Picker(
                selection: Binding(
                    get: { model.selectedEndpoint }, set: { if let url = $0 { model.chooseEndpoint(url) } })
            ) {
                ForEach(model.endpoints) { endpoint in
                    Text(endpoint.name).tag(Optional(endpoint.baseURL))
                }
            } label: {
                Text("Server", comment: "Dictation settings label of the formatting server")
            }
            Picker(selection: Binding(get: { model.selectedModel }, set: { model.chooseModel($0) })) {
                ForEach(model.models, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            } label: {
                Text("Model", comment: "Dictation settings label of the formatting model")
            }
        }
        TextField(text: $model.address, prompt: Text(verbatim: "http://127.0.0.1:11434")) {
            Text("Address", comment: "Dictation settings label of the formatting server address")
        }
        .onSubmit { model.checkAddress() }
        if model.addressError {
            Text(
                "Only addresses on this Mac are allowed: localhost, 127.x.x.x or [::1].",
                comment: "Dictation settings error for a server address that is not on this Mac"
            )
            .font(.callout).foregroundStyle(.red)
        }
        Text(
            "Recommended: Qwen3.6-35B-A3B (4-bit). Best Polish: Bielik-11B-v3.0-Instruct. Light: Qwen3-4B-Instruct-2507.",
            comment: "Dictation settings recommendation of formatting models"
        )
        .font(.callout).foregroundStyle(.secondary)
    }

    @ViewBuilder private var tryRows: some View {
        LabeledContent {
            Button {
                model.tryIt()
            } label: {
                Text("Try it", comment: "Dictation settings button that cleans up a sample text")
            }
            .disabled(model.tryState == .running)
        } label: {
            Text(FormattingSettingsModel.sample).font(.callout).foregroundStyle(.secondary)
        }
        switch model.tryState {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .result(_, let text, let cleaned):
            VStack(alignment: .leading, spacing: 4) {
                Text(text).textSelection(.enabled)
                if !cleaned {
                    Text(
                        "The server did not give a usable answer, so this is the raw text.",
                        comment: "Dictation settings note when Try it fell back to the raw text"
                    )
                    .font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }
}

/// The built-in formatting model: the list of catalog models, their size and memory, and download or remove.
struct BuiltInModelRows: View {
    @Bindable var model: FormattingSettingsModel

    private func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }

    var body: some View {
        Picker(selection: Binding(get: { model.builtInModel.id }, set: { model.chooseBuiltInModel($0) })) {
            ForEach(model.builtInModels) { entry in
                Text(entry.package.title).tag(entry.id)
            }
        } label: {
            Text("Model", comment: "Dictation settings label of the formatting model")
        }
        Text(
            "Download \(bytes(model.builtInModel.package.totalBytes)), about \(bytes(model.builtInModel.residentBytes)) of memory while loaded. \(model.builtInModel.package.license) licence.",
            comment: "Dictation settings size and memory of the built-in model"
        )
        .font(.callout).foregroundStyle(.secondary)
        if let progress = model.builtInProgress {
            ProgressView(value: progress.fraction) {
                Text("Downloading…", comment: "Dictation settings progress label")
            }
            .accessibilityValue(Text(progress.fraction, format: .percent.precision(.fractionLength(0))))
            Button {
                model.cancelDownload()
            } label: {
                Text("Cancel", comment: "Button that cancels the model download")
            }
        } else if model.isBuiltInInstalled {
            LabeledContent {
                Button(role: .destructive) {
                    model.removeBuiltIn()
                } label: {
                    Text("Remove", comment: "Button that deletes the downloaded model")
                }
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
                    model.downloadBuiltIn()
                } label: {
                    Text(
                        "Download (≈ \(bytes(model.builtInModel.package.totalBytes)))",
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
        if let message = model.builtInError {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            }
            .foregroundStyle(.orange)
        }
    }
}

/// Settings → Dictation → History: keep finished dictations (encrypted), for how long, and clear them.
struct HistorySection: View {
    @Bindable var model: HistorySettingsModel
    @State private var confirmsClear = false

    var body: some View {
        Section {
            Toggle(isOn: $model.isEnabled) {
                Text("Keep a history of dictations", comment: "Dictation settings toggle for the history")
            }
            if model.isEnabled {
                Picker(selection: $model.retentionDays) {
                    ForEach(model.dayChoices(), id: \.self) { days in
                        Text("\(days) days", comment: "Dictation settings retention choice").tag(days)
                    }
                } label: {
                    Text("Keep for", comment: "Dictation settings label of the retention period")
                }
                Picker(selection: $model.maximumEntries) {
                    ForEach(model.entryChoices(), id: \.self) { count in
                        Text("\(count) entries", comment: "Dictation settings entry limit choice").tag(count)
                    }
                } label: {
                    Text("At most", comment: "Dictation settings label of the entry limit")
                }
                LabeledContent {
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Text("Clear History…", comment: "Dictation settings button that deletes the history")
                    }
                    .disabled(model.history.entryCount == 0)
                } label: {
                    Text(
                        "\(model.history.entryCount) entries",
                        comment: "Dictation settings count of saved dictations")
                }
                historyStatus
            }
            if let message = model.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("History", comment: "Dictation settings section title")
        } footer: {
            Text(
                "The text of every dictation is stored on this Mac, encrypted with a key in your Keychain. Audio is never stored. Open it from the menu bar: Dictation History.",
                comment: "Dictation settings footer under the history toggle"
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .confirmationDialog(
            Text("Clear the dictation history?", comment: "Dictation settings confirmation title"),
            isPresented: $confirmsClear
        ) {
            Button(role: .destructive) {
                model.clear()
            } label: {
                Text("Clear History", comment: "Dictation settings confirmation button")
            }
        } message: {
            Text(
                "This deletes every saved dictation. It cannot be undone.",
                comment: "Dictation settings confirmation text")
        }
    }

    @ViewBuilder private var historyStatus: some View {
        switch model.history.status {
        case .unavailable:
            Text(
                "The history is unavailable because the Keychain could not be read. Nothing was deleted.",
                comment: "Dictation history banner when the Keychain key is unavailable"
            )
            .font(.callout).foregroundStyle(.orange)
        case .failed:
            Text(
                "The history could not be opened.",
                comment: "Dictation history banner when the database could not be opened"
            )
            .font(.callout).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// The history list when nothing is saved yet (or the history is off).
struct DictationHistoryEmptyView: View {
    let history: DictationHistory

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
            Text(
                history.status == .closed
                    ? String(
                        localized: "The dictation history is off. Turn it on in Settings → Dictation.",
                        comment: "Dictation history empty state when the history is off")
                    : String(
                        localized: "No dictations yet.", comment: "Dictation history empty state")
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
