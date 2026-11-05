import LintelKit
import LintelUI
import SwiftUI

/// Settings → Dictation in the old Settings window (`settingsHostStyle == .legacyWindow`), unchanged since step
/// 3.3: the model cards, the microphone rows and the in-body history status. The main window draws
/// `DictationPaneContent` instead (step 5.1). Deleted with the old window in step 6.3b.
struct LegacyDictationSettingsPane: View {
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
                if hostStyle == .legacyWindow {
                    SpeechModelCard(model: model)
                } else {
                    ModelChoiceRow(title: model.package.title, state: model.choiceState) {
                        openModels(model.package.id)
                    }
                }
            } header: {
                Text("Speech model", comment: "Dictation settings section title")
            } footer: {
                Text(
                    "The model runs on this Mac. Audio is never sent anywhere and never saved.",
                    comment: "Dictation settings footer under the speech model"
                )
                .font(.callout).foregroundStyle(.secondary)
            }

            FormattingSection(model: formatting, openModels: openModels)

            Section {
                InputDevicePicker(model: model)
                if hostStyle == .legacyWindow {
                    MicrophoneRows(model: model)
                }
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
