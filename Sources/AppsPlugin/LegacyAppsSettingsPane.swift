import LintelUI
import SwiftUI

/// Settings → Applications in the old window (`settingsHostStyle == .legacyWindow`, what release users see):
/// suggestions (toggle, privacy note, hidden apps, Clear App Activity…) and the app index (Spotlight, searched
/// folders). Kept unchanged until the old window is deleted in spec step 6.3b; the main window draws
/// `AppsPaneContent` instead (step 4.2).
struct LegacyAppsSettingsPane: View {
    let model: AppsSettingsModel

    @State private var confirmsClear = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.suggestionsEnabled }, set: { model.setSuggestionsEnabled($0) })) {
                    Text("Suggest Apps", comment: "Settings toggle that turns app suggestions on")
                    Text(
                        "Lintel records on this Mac which apps you use and how often, to suggest them. Nothing leaves your Mac.",
                        comment: "Settings description of what app suggestions record"
                    )
                }
                if model.isReadOnly {
                    Label {
                        Text(
                            "App activity was saved by a newer version of Lintel. Suggestions are off until you update.",
                            comment: "Settings message when activity.json comes from a newer version"
                        )
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .symbolRenderingMode(.hierarchical)
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                hiddenApps
                LabeledContent {
                    Button {
                        confirmsClear = true
                    } label: {
                        Text("Clear App Activity…", comment: "Button that deletes the recorded app activity")
                    }
                    .disabled(model.isReadOnly)
                } label: {
                    Text("Recorded activity", comment: "Settings label next to Clear App Activity")
                }
            } header: {
                Text("Suggestions", comment: "Settings section title")
            }

            Section {
                Toggle(isOn: Binding(get: { model.spotlightEnabled }, set: { model.setSpotlightEnabled($0) })) {
                    Text("Find apps with Spotlight", comment: "Settings toggle for the Spotlight app supplement")
                    Text(
                        "Also lists apps outside the searched folders that Spotlight knows.",
                        comment: "Settings description of the Spotlight app supplement"
                    )
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.roots(), id: \.self) { root in
                        Label {
                            Text(root.path(percentEncoded: false))
                                .truncationMode(.middle)
                                .lineLimit(1)
                        } icon: {
                            Image(systemName: "folder")
                                .accessibilityHidden(true)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text("Searched folders", comment: "Settings section title"))
            } header: {
                Text("App index", comment: "Settings section title")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.columnWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.reload() }
        .destructiveConfirmation(isPresented: $confirmsClear, AppsSettingsPane.confirmation) {
            Task { await model.clearActivity() }
        }
    }

    /// The apps hidden with "Hide from Suggestions", each with a button that shows it again.
    @ViewBuilder private var hiddenApps: some View {
        if !model.hidden.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hidden from suggestions", comment: "Settings label above the list of hidden apps")
                ForEach(model.hidden, id: \.self) { bundleID in
                    let name = model.displayName(of: bundleID)
                    HStack {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            model.restore(bundleID)
                        } label: {
                            Text("Show Again", comment: "Button that shows a hidden app in suggestions again")
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
        }
    }
}
