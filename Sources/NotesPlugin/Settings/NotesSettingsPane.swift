import LintelKit
import LintelUI
import SwiftUI

/// Settings → Notes on the `SettingsPane` template (spec step 4.7; the prototype has no Notes pane, so it follows
/// `set-meetings` and `set-dictation`): Basics (the notes model, the Details toggles) and Data (Export All Notes…,
/// Erase Notes Data…). The banner is the host's; the pane has none of its own.
struct NotesSettingsPane: View {
    let model: NotesPaneModel

    var body: some View {
        NotesPaneContent(model: model)
    }
}

enum NotesConfirmations {
    static let erase = DestructiveConfirmation(
        prompt: LocalizedStringResource("Erase all Notes data?", comment: "Notes settings confirmation title"),
        detail: LocalizedStringResource(
            "The notes you wrote, your edits and comments on recorded notes and their history are removed from this Mac, with the library’s key. Recordings in Meetings and Dictation stay. This can’t be undone.",
            comment: "Notes settings confirmation text of Erase Notes Data"),
        confirmTitle: LocalizedStringResource(
            "Erase Data", comment: "Confirmation button that deletes a feature's data"))
}

struct NotesPaneContent: View {
    let model: NotesPaneModel
    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmErase = false

    var body: some View {
        @Bindable var preferences = model.preferences
        SettingsPane {
            Section {
                modelRow
                toggle(
                    Text("Author bars", comment: "Inspector, Details: toggle for the author bars"),
                    help: Text(
                        "Who wrote each block: AI, You, STT.",
                        comment: "Inspector, Details: what the author bars show"), isOn: $preferences.showAuthorBars)
                toggle(
                    Text("Source quotes", comment: "Inspector, Details: toggle for the quote chips"),
                    help: Text(
                        "Timestamps that open the transcript.",
                        comment: "Inspector, Details: what the quote chips do"), isOn: $preferences.showQuotes)
                toggle(
                    Text("Wrap lines", comment: "Inspector, Details: toggle for wrapping long lines in the editor"),
                    help: nil, isOn: $preferences.wrapLines)
            } header: {
                Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                    .settingsSectionHeader()
            }
        } data: {
            dataRows
        }
        .task { await model.refresh() }
        .onChange(of: model.message) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .destructiveConfirmation(isPresented: $confirmErase, NotesConfirmations.erase) {
            Task { await model.erase() }
        }
    }

    // MARK: Basics

    private var modelRow: some View {
        MenuPicker(
            selection: Binding(get: { model.selectedID }, set: { id in Task { await model.choose(id) } }),
            title: Text("Notes model", comment: "Settings → Meetings label of the model that writes the notes")
        ) {
            ForEach(model.choices) { choice in
                Text(choice.title).font(textSize.font(.body)).tag(choice.id)
            }
        } label: {
            Text("Notes model", comment: "Settings → Meetings label of the model that writes the notes")
                .font(textSize.font(.body))
            ModelChoiceRow(title: model.selectedTitle, state: model.choiceState, style: .help) {
                openModels()
            }
        }
    }

    /// The Models pane on the chosen model's row (`PluginContext.openModels`, handed in by the plugin).
    private func openModels() {
        model.openModels(model.selectedID)
    }

    @ViewBuilder
    private func toggle(_ title: Text, help: Text?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                title.font(textSize.font(.body))
                if let help { help.font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText) }
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: Data

    @ViewBuilder private var dataRows: some View {
        LabeledContent {
            Button {
                Task { await model.exportAll() }
            } label: {
                Text("Export All Notes…", comment: "Notes settings button that exports every note to a folder")
                    .font(textSize.font(.body))
            }
            .disabled(!model.canExport)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Export", comment: "Notes settings row of the export")
                    .font(textSize.font(.body))
                Text(
                    "One Markdown file per note, and a manifest.",
                    comment: "Notes settings: help under Export All Notes"
                )
                .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
            }
        }
        LabeledContent {
            Button(role: .destructive) {
                confirmErase = true
            } label: {
                Text("Erase Notes Data…", comment: "Notes settings button that erases the Notes library")
                    .font(textSize.font(.body))
            }
            .lintelDestructiveButton()
            .disabled(!model.canErase)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Erase Data", comment: "Meetings settings row that erases the data, and its confirmation button")
                    .font(textSize.font(.body))
                Text(
                    "Notes you wrote and your edits. Recordings stay.",
                    comment: "Notes settings: help under Erase Notes Data"
                )
                .font(textSize.font(.callout)).foregroundStyle(LintelBrand.secondaryText)
            }
        }
        if let message = model.message {
            Text(message)
                .font(textSize.font(.callout))
                .foregroundStyle(model.isFailure ? LintelBrand.statusError : LintelBrand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
