import LintelKit
import LintelUI
import SwiftUI

/// Settings → Dictation. The main window draws `DictationPaneContent` on the `SettingsPane` template (prototype
/// `set-dictation`, spec step 5.1); the old window keeps `LegacyDictationSettingsPane` with its model cards,
/// microphone rows and in-body history status. The main window's banner is the host's, from
/// `DictationPlugin.settingsStatus`.
struct DictationSettingsPane: View {
    @Bindable var model: DictationSettingsModel
    @Bindable var formatting: FormattingSettingsModel
    @Bindable var history: HistorySettingsModel
    let recorder: AnyView
    /// `false` while the plugin is off (the main window shows the pane dimmed): the pane then probes no
    /// server and reads no model folder (`settingsPane()` must not start work while inactive).
    var isActive = true
    /// `PluginContext.openModels`: the Models pane on the package's row.
    var openModels: (String?) -> Void = { _ in }
    @Environment(\.settingsHostStyle) private var hostStyle

    var body: some View {
        if hostStyle == .legacyWindow {
            LegacyDictationSettingsPane(
                model: model, formatting: formatting, history: history, recorder: recorder, isActive: isActive,
                openModels: openModels)
        } else {
            DictationPaneContent(
                model: model, formatting: formatting, history: history, recorder: recorder, isActive: isActive,
                openModels: openModels)
        }
    }
}

/// The main window's Dictation pane (prototype `set-dictation`): Basics (Dictate, Speech model with its
/// one-line summary, Clean up text and, while it is on, where it runs), a collapsed Advanced (Input device,
/// restore the clipboard) and History (Keep a history, Keep for, At most, Clear History…). The model, the
/// microphone and the history's state are the host's banner; downloads live in Models, the microphone in
/// Permissions.
struct DictationPaneContent: View {
    @Bindable var model: DictationSettingsModel
    @Bindable var formatting: FormattingSettingsModel
    @Bindable var history: HistorySettingsModel
    let recorder: AnyView
    var isActive = true
    var openModels: (String?) -> Void = { _ in }

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmsClear = false

    var body: some View {
        SettingsPane(
            dataTitle: LocalizedStringResource("History", comment: "Dictation settings section title")
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
            historyRows
        }
        .destructiveConfirmation(isPresented: $confirmsClear, HistorySection.confirmation) {
            history.clear()
        }
        .task(id: isActive) {
            guard isActive else { return }
            await model.refresh()
            await formatting.refresh()
        }
    }

    // MARK: Basics

    @ViewBuilder private var basics: some View {
        LabeledContent {
            recorder
        } label: {
            label(
                Text("Dictate", comment: "Menu item and command that starts dictation"),
                help: Text(
                    "Press to start and again to stop, or hold.",
                    comment: "Settings → Dictation: help under the Dictate shortcut"))
        }
        LabeledContent {
            Picker(selection: Binding(get: { model.speechModelID }, set: { model.selectSpeechModel($0) })) {
                ForEach(model.packages) { package in
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
            ModelChoiceRow(title: model.package.title, state: model.choiceState, style: .help) {
                openModels(model.package.id)
            }
        }
        if model.usesPinnedLanguage {
            // Whisper listens for one language; Parakeet needs no choice (the prototype's automatic row is dropped).
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
        Toggle(isOn: Binding(get: { formatting.isCleanupOn }, set: { formatting.mode = $0 ? .cleanup : .raw })) {
            label(
                Text("Clean up text", comment: "Settings → Dictation: switch that formats the text"), help: cleanupHelp)
        }
        .toggleStyle(.switch)
        if formatting.isCleanupOn {
            cleanupRows
        }
    }

    private var cleanupHelp: Text {
        if !formatting.isBuiltIn && (formatting.isCleanupOn || !formatting.offersBuiltIn) {
            Text(
                "Your server on this Mac fixes punctuation and filler words.",
                comment: "Settings → Dictation: help under Clean up text when the user's server formats")
        } else {
            Text(
                "Built-in model fixes punctuation and filler words.",
                comment: "Settings → Dictation: help under Clean up text")
        }
    }

    @ViewBuilder private var cleanupRows: some View {
        if formatting.offersBuiltIn {
            MenuPicker(selection: $formatting.source) {
                Text("Built-in (Lintel)", comment: "Dictation settings choice of the built-in formatting model")
                    .font(textSize.font(.body))
                    .tag(DictationSettings.LLMSource.builtIn)
                Text("My server", comment: "Dictation settings choice of the user's formatting server")
                    .font(textSize.font(.body))
                    .tag(DictationSettings.LLMSource.server)
            } label: {
                Text("Run on", comment: "Dictation settings label of the formatting source")
                    .font(textSize.font(.body))
            }
        }
        if formatting.isBuiltIn {
            MenuPicker(
                selection: Binding(
                    get: { formatting.builtInModel.id }, set: { formatting.chooseBuiltInModel($0) }),
                title: Text("Model", comment: "Dictation settings label of the formatting model")
            ) {
                ForEach(formatting.builtInModels) { entry in
                    Text(entry.package.title).font(textSize.font(.body)).tag(entry.id)
                }
            } label: {
                Text("Model", comment: "Dictation settings label of the formatting model")
                    .font(textSize.font(.body))
                ModelChoiceRow(
                    title: formatting.builtInModel.package.title, state: formatting.builtInChoiceState, style: .help
                ) {
                    openModels(formatting.builtInModel.id)
                }
            }
        } else {
            serverRows
        }
        if formatting.hasTarget {
            tryRows
        }
    }

    @ViewBuilder private var serverRows: some View {
        if formatting.endpoints.isEmpty {
            LabeledContent {
                if formatting.isProbing {
                    ProgressView().controlSize(.small)
                }
            } label: {
                Text(
                    formatting.isProbing ? "Looking for a server…" : "No server found on this Mac",
                    comment: "Dictation settings status of the formatting server"
                )
                .font(textSize.font(.body))
            }
        } else {
            MenuPicker(
                selection: Binding(
                    get: { formatting.selectedEndpoint },
                    set: { if let url = $0 { formatting.chooseEndpoint(url) } })
            ) {
                ForEach(formatting.endpoints) { endpoint in
                    Text(endpoint.name).font(textSize.font(.body)).tag(Optional(endpoint.baseURL))
                }
            } label: {
                Text("Server", comment: "Dictation settings label of the formatting server")
                    .font(textSize.font(.body))
            }
            MenuPicker(selection: Binding(get: { formatting.selectedModel }, set: { formatting.chooseModel($0) })) {
                ForEach(formatting.models, id: \.self) { name in
                    Text(name).font(textSize.font(.body)).tag(Optional(name))
                }
            } label: {
                Text("Model", comment: "Dictation settings label of the formatting model")
                    .font(textSize.font(.body))
            }
        }
        TextField(text: $formatting.address, prompt: Text(verbatim: "http://127.0.0.1:11434")) {
            Text("Address", comment: "Dictation settings label of the formatting server address")
                .font(textSize.font(.body))
        }
        .font(textSize.font(.body))
        .onSubmit { formatting.checkAddress() }
        if formatting.addressError {
            Text(
                "Only addresses on this Mac are allowed: localhost, 127.x.x.x or [::1].",
                comment: "Dictation settings error for a server address that is not on this Mac"
            )
            .font(textSize.font(.callout))
            .foregroundStyle(LintelBrand.statusError)
        }
        SettingsFooter(
            LocalizedStringResource(
                "Recommended: Qwen3.6-35B-A3B (4-bit). Best Polish: Bielik-11B-v3.0-Instruct. Light: Qwen3-4B-Instruct-2507.",
                comment: "Dictation settings recommendation of formatting models"))
    }

    @ViewBuilder private var tryRows: some View {
        LabeledContent {
            Button {
                formatting.tryIt()
            } label: {
                Text("Try it", comment: "Dictation settings button that cleans up a sample text")
                    .font(textSize.font(.body))
            }
            .disabled(formatting.tryState == .running)
        } label: {
            Text(FormattingSettingsModel.sample)
                .font(textSize.font(.callout))
                .foregroundStyle(.secondary)
        }
        switch formatting.tryState {
        case .idle: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .result(_, let text, let cleaned):
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(textSize.font(.body))
                    .textSelection(.enabled)
                if !cleaned {
                    Text(
                        "The server did not give a usable answer, so this is the raw text.",
                        comment: "Dictation settings note when Try it fell back to the raw text"
                    )
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.statusAttention)
                }
            }
        }
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        MenuPicker(selection: $model.inputDevice) {
            Text("System default", comment: "Dictation input device choice that follows the system").font(
                textSize.font(.body)
            ).tag(String?.none)
            ForEach(model.devices) { device in
                Text(device.name).font(textSize.font(.body)).tag(Optional(device.uid))
            }
        } label: {
            Text("Input device", comment: "Dictation settings label")
                .font(textSize.font(.body))
        }
        Toggle(isOn: $model.restoresClipboard) {
            Text("Restore the clipboard after pasting", comment: "Dictation settings toggle")
                .font(textSize.font(.body))
        }
        .toggleStyle(.switch)
        SettingsFooter(
            LocalizedStringResource(
                "Lintel pastes through the clipboard and puts back what was there a second later.",
                comment: "Settings → Dictation: footer under the clipboard restore switch"))
    }

    // MARK: History

    @ViewBuilder private var historyRows: some View {
        Toggle(isOn: $history.isEnabled) {
            label(
                Text("Keep a history", comment: "Settings → Dictation: switch that keeps finished dictations"),
                help: Text(
                    "Encrypted on this Mac.", comment: "Settings → Clipboard: help under History in Data"))
        }
        .toggleStyle(.switch)
        MenuPicker(selection: $history.retentionDays) {
            ForEach(history.dayChoices(), id: \.self) { days in
                Text("\(days) days", comment: "Dictation settings retention choice").font(textSize.font(.body)).tag(
                    days)
            }
        } label: {
            Text("Keep for", comment: "Dictation settings label of the retention period")
                .font(textSize.font(.body))
        }
        .disabled(!history.isEnabled)
        MenuPicker(selection: $history.maximumEntries) {
            ForEach(history.entryChoices(), id: \.self) { count in
                Text("\(count) entries", comment: "Dictation settings entry limit choice").font(textSize.font(.body))
                    .tag(count)
            }
        } label: {
            Text("At most", comment: "Dictation settings label of the entry limit")
                .font(textSize.font(.body))
        }
        .disabled(!history.isEnabled)
        LabeledContent {
            Button(role: .destructive) {
                confirmsClear = true
            } label: {
                Text("Clear History…", comment: "Dictation settings button that deletes the history")
                    .font(textSize.font(.body))
            }
            .disabled(history.history.status != .ready || history.history.entryCount == 0)
        } label: {
            Text("History", comment: "Dictation settings section title")
                .font(textSize.font(.body))
        }
        if let message = history.errorMessage {
            Text(message)
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.statusError)
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
