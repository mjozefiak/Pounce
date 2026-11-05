import LintelUI
import SwiftUI

/// Settings → Applications: `AppsPaneContent` on the `SettingsPane` template (prototype `set-apps`, spec step
/// 4.2). The banner is the host's, from `AppsPlugin.settingsStatus`.
struct AppsSettingsPane: View {
    let model: AppsSettingsModel

    /// The Reset Suggestions question.
    static let resetConfirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource(
            "Reset suggestions?", comment: "Settings → Apps: Reset Suggestions confirmation title"),
        detail: LocalizedStringResource(
            "Lintel forgets which apps you used. This can’t be undone.",
            comment: "Settings → Apps: Reset Suggestions confirmation message"),
        confirmTitle: LocalizedStringResource(
            "Reset Suggestions", comment: "Settings → Apps: Reset Suggestions confirmation button"))

    var body: some View {
        AppsPaneContent(model: model)
    }
}

/// The Apps pane (prototype `set-apps`): Basics (Suggest apps, Hidden suggestions), Advanced (the
/// app index: Spotlight and the searched folders) and Data (usage history, Reset Suggestions…).
struct AppsPaneContent: View {
    let model: AppsSettingsModel

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmsReset = false
    @State private var managesHidden = false

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: Binding(get: { model.suggestionsEnabled }, set: { model.setSuggestionsEnabled($0) })) {
                    Text("Suggest apps", comment: "Settings → Apps: switch that turns app suggestions on")
                        .font(textSize.font(.body))
                    Text(
                        "Shown when the launcher is empty.",
                        comment: "Settings → Apps: help under the Suggest apps switch"
                    )
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
                }
                .toggleStyle(.switch)
                LabeledContent {
                    Button {
                        managesHidden = true
                    } label: {
                        Text("Manage…", comment: "Settings → Apps: button that lists the apps hidden from suggestions")
                            .font(textSize.font(.body))
                    }
                } label: {
                    Text("Hidden suggestions", comment: "Settings → Apps: label of the hidden apps row")
                        .font(textSize.font(.body))
                }
            } header: {
                Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                    .settingsSectionHeader()
            }
        } advanced: {
            Toggle(isOn: Binding(get: { model.spotlightEnabled }, set: { model.setSpotlightEnabled($0) })) {
                Text("Find apps with Spotlight", comment: "Settings toggle for the Spotlight app supplement")
                    .font(textSize.font(.body))
                Text(
                    "Also lists apps outside the searched folders that Spotlight knows.",
                    comment: "Settings description of the Spotlight app supplement"
                )
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
            }
            .toggleStyle(.switch)
            SearchedFoldersRow(roots: model.roots())
        } data: {
            LabeledContent {
                Button(role: .destructive) {
                    confirmsReset = true
                } label: {
                    Text(
                        "Reset Suggestions…", comment: "Settings → Apps: button that deletes the recorded app activity"
                    )
                    .font(textSize.font(.body))
                }
                .lintelDestructiveButton()
                .disabled(model.isReadOnly)
            } label: {
                Text("Usage history", comment: "Settings → Apps: label of the recorded app activity row")
                    .font(textSize.font(.body))
                Text("Stored on this Mac only.", comment: "Settings → Apps: help under Usage history")
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.secondaryText)
            }
        }
        .onAppear { model.reload() }
        .destructiveConfirmation(isPresented: $confirmsReset, AppsSettingsPane.resetConfirmation) {
            Task { await model.clearActivity() }
        }
        .sheet(isPresented: $managesHidden) {
            HiddenSuggestionsSheet(model: model) { managesHidden = false }
        }
    }
}

/// The folders the app index scans, one per line.
struct SearchedFoldersRow: View {
    let roots: [URL]

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Searched folders", comment: "Settings section title")
                .font(textSize.font(.body))
            ForEach(roots, id: \.self) { root in
                Label {
                    Text(root.path(percentEncoded: false))
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .truncationMode(.middle)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "folder")
                        .font(textSize.font(.callout))
                        .foregroundStyle(LintelBrand.secondaryText)
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "Manage…": the apps hidden with "Hide from Suggestions", each with a button that shows it again.
struct HiddenSuggestionsSheet: View {
    let model: AppsSettingsModel
    let done: () -> Void

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hidden suggestions", comment: "Settings → Apps: label of the hidden apps row")
                .font(textSize.font(.headline))
            if model.hidden.isEmpty {
                Text(
                    "No apps are hidden. Hide one from its suggestion in the launcher.",
                    comment: "Settings → Apps: the hidden apps sheet when nothing is hidden"
                )
                .font(textSize.font(.callout))
                .foregroundStyle(LintelBrand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.hidden, id: \.self) { bundleID in
                    let name = model.displayName(of: bundleID)
                    HStack {
                        Text(name)
                            .font(textSize.font(.body))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.restore(bundleID)
                        } label: {
                            Text("Show Again", comment: "Button that shows a hidden app in suggestions again")
                                .font(textSize.font(.body))
                        }
                        .accessibilityLabel(
                            Text(
                                "Show \(name) Again",
                                comment:
                                    "Accessibility label of the button that shows a hidden app in suggestions again"
                            ))
                    }
                }
            }
            HStack {
                Spacer()
                Button(action: done) {
                    Text("Done", comment: "Button that closes a sheet")
                        .font(textSize.font(.body))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20 * textSize.scale)
        // Grows with the text size, so names and buttons fit at XL.
        .frame(minWidth: 380 * textSize.scale, idealWidth: 380 * textSize.scale)
    }
}
