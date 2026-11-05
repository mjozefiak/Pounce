import LintelKit
import LintelUI
import SwiftUI

// The old Settings window's General and Features panes (`settingsHostStyle == .legacyWindow`, what release users
// see), kept unchanged until the old window is deleted in spec step 6.3b. The main window draws `GeneralPane` and
// `FeaturesPane` on the `SettingsPane` template instead (step 4.1).

/// Settings → General in the old window: the main shortcut, launch at login, the Dock icon and the panel's text
/// size.
struct LegacyGeneralPane: View {
    let hotkeys: HotkeyService
    @Bindable var settings: AppSettings
    let launchAtLogin: any LaunchAtLoginClient

    @State private var launchesAtLogin = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    MainShortcutRecorder(hotkeys: hotkeys)
                } label: {
                    Text("Open Lintel", comment: "Settings label of the main shortcut")
                }
                if hotkeys.spotlightHoldsCommandSpace {
                    SpotlightShortcutBanner()
                }
            } header: {
                Text("Shortcut", comment: "Settings section title")
            }

            Section {
                Toggle(isOn: launchBinding) {
                    Text("Launch at login", comment: "Settings toggle")
                }
                if let launchError {
                    Text(launchError)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.showInDock) {
                    Text("Show in Dock", comment: "Settings toggle")
                }
            } footer: {
                Text("Lintel stays in the menu bar either way.", comment: "Settings footer for the Dock toggle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $settings.textSize) {
                    ForEach(TextSize.allCases) { size in
                        Text(size.title)
                            .accessibilityLabel(Text(size.accessibilityName))
                            .tag(size)
                    }
                } label: {
                    Text("Text size", comment: "Settings label of the panel text size")
                }
                .pickerStyle(.segmented)
                // The segments show S, M, L and XL; VoiceOver reads the size in words.
                .accessibilityValue(Text(settings.textSize.accessibilityName))
            } footer: {
                Text("Changes the size of text in the Lintel panel.", comment: "Settings footer for text size")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.columnWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchesAtLogin = launchAtLogin.isEnabled
        }
    }

    private var launchBinding: Binding<Bool> {
        Binding {
            launchesAtLogin
        } set: { enabled in
            do {
                try launchAtLogin.setEnabled(enabled)
                launchError = nil
            } catch {
                launchError = error.localizedDescription
            }
            launchesAtLogin = launchAtLogin.isEnabled
        }
    }
}

/// Settings → Features in the old window: every plugin with its switch, its state (an activation error
/// included) and "Erase Data", and the order of the result sections.
struct LegacyFeaturesPane: View {
    let controls: FeatureControls
    let order: SectionOrderControls?

    @State private var eraseError: String?

    var body: some View {
        Form {
            Section {
                ForEach(controls.host.entries, id: \.manifest.id) { entry in
                    FeatureRow(
                        manifest: entry.manifest,
                        state: entry.state,
                        isEnabled: controls.isEnabled(entry.manifest.id),
                        setEnabled: { enabled in
                            Task { await controls.setEnabled(enabled, for: entry.manifest.id) }
                        },
                        erase: {
                            Task { eraseError = await controls.erase(entry.manifest.id) }
                        }
                    )
                }
            } header: {
                Text("Features", comment: "Settings section title")
            } footer: {
                Text(
                    "Turning a feature off stops it and hides its results. Its data stays until you erase it.",
                    comment: "Settings footer for the feature list"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if let order, order.ordered.count > 1 {
                SectionOrderSection(order: order)
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.columnWidth)
        .fixedSize(horizontal: false, vertical: true)
        .alert(
            Text("The data could not be erased.", comment: "Alert title when Erase Data fails"),
            isPresented: Binding(get: { eraseError != nil }, set: { if !$0 { eraseError = nil } })
        ) {
            Button {
                eraseError = nil
            } label: {
                Text("OK", comment: "Button that dismisses an alert")
            }
        } message: {
            Text(eraseError ?? "")
        }
    }
}

struct FeatureRow: View {
    let manifest: PluginManifest
    let state: PluginState
    let isEnabled: Bool
    let setEnabled: (Bool) -> Void
    let erase: () -> Void

    @State private var confirmsErase = false

    /// The words of Erase Data for one feature.
    static func confirmation(for manifest: PluginManifest) -> DestructiveConfirmation {
        DestructiveConfirmation(
            prompt: LocalizedStringResource(
                "Erase all data of “\(String(localized: manifest.displayName))”?", comment: "Erase confirmation title"),
            detail: LocalizedStringResource(
                "This deletes everything the feature stored on this Mac. It cannot be undone.",
                comment: "Erase confirmation message"),
            confirmTitle: LocalizedStringResource(
                "Erase Data", comment: "Confirmation button that deletes a feature's data"),
            mainWindowDetail: LocalizedStringResource(
                "This deletes everything the feature stored on this Mac. This can’t be undone.",
                comment: "Erase confirmation message in the main window"))
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: manifest.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(manifest.displayName)
                status
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button {
                confirmsErase = true
            } label: {
                Text("Erase Data…", comment: "Settings button that deletes a feature's data")
            }
            // Every row has this button: VoiceOver needs the feature's name to tell them apart.
            .accessibilityLabel(
                Text(
                    "Erase Data of \(String(localized: manifest.displayName))…",
                    comment: "Accessibility label of a feature's Erase Data button"))
            Toggle(isOn: Binding(get: { isEnabled }, set: { setEnabled($0) })) {
                Text(manifest.displayName)
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .destructiveConfirmation(isPresented: $confirmsErase, Self.confirmation(for: manifest), onConfirm: erase)
    }

    @ViewBuilder private var status: some View {
        switch state {
        case .active:
            Text("On", comment: "Feature state")
        case .disabled:
            Text("Off", comment: "Feature state")
        case .activating:
            Text("Starting…", comment: "Feature state")
        case .failed(let error):
            Label {
                Text("Unavailable: \(error.localizedDescription)", comment: "Feature state with the error message")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .symbolRenderingMode(.hierarchical)
            }
        }
    }
}

extension PluginID {
    /// The id of this plugin's row in the Result Order list.
    fileprivate var orderRowID: String { "order:\(rawValue)" }
}

/// "Result order": each search section with Move Up and Move Down buttons (reachable with Tab, unlike
/// drag and drop).
struct SectionOrderSection: View {
    let order: SectionOrderControls

    var body: some View {
        let entries = order.ordered
        Section {
            // Row ids differ from the feature list's (plugin ids): the grouped form is one list, and equal
            // ids in two sections make it draw a feature row in the wrong place.
            ForEach(Array(entries.enumerated()), id: \.element.manifest.id.orderRowID) { index, entry in
                HStack(spacing: 12) {
                    Text("\(index + 1).", comment: "Position in the result order list")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Image(systemName: entry.manifest.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    Text(entry.manifest.displayName)
                    Spacer()
                    Button {
                        order.move(entry.manifest.id, by: -1)
                    } label: {
                        Label {
                            Text("Move Up", comment: "Button that moves a result section up")
                        } icon: {
                            Image(systemName: "chevron.up")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .disabled(index == 0)
                    .help(Text("Move Up", comment: "Button that moves a result section up"))
                    Button {
                        order.move(entry.manifest.id, by: 1)
                    } label: {
                        Label {
                            Text("Move Down", comment: "Button that moves a result section down")
                        } icon: {
                            Image(systemName: "chevron.down")
                        }
                        .labelStyle(.iconOnly)
                    }
                    .disabled(index == entries.count - 1)
                    .help(Text("Move Down", comment: "Button that moves a result section down"))
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(
                    Text(
                        "\(String(localized: entry.manifest.displayName)), position \(index + 1) of \(entries.count)",
                        comment: "Accessibility label of a result section in the order list"))
            }
        } header: {
            Text("Result Order", comment: "Settings section title")
        } footer: {
            HStack(alignment: .firstTextBaseline) {
                Text(
                    "Sections appear in the panel in this order.",
                    comment: "Settings footer of the result order"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    order.restoreDefault()
                } label: {
                    Text("Restore Default Order", comment: "Button that restores the default result order")
                }
                .disabled(order.settings.sectionOrder.isEmpty)
            }
        }
    }
}

/// Settings → Advanced in the old window (`settingsHostStyle == .legacyWindow`, what release users see), kept
/// unchanged until the old window is deleted in spec step 6.3b.
struct LegacyAdvancedPane: View {
    let controls: AdvancedControls

    @State private var confirmsReset = false
    @State private var resetDone = false
    @State private var resetError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button {
                        confirmsReset = true
                    } label: {
                        Text("Reset Ranking…", comment: "Settings button that clears the learned ranking")
                    }
                    .lintelDestructiveButton()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ranking", comment: "Settings label of the ranking reset")
                        Text(
                            "Lintel moves the results you pick often to the top. Resetting forgets what it learned; your apps, files and clipboard history stay.",
                            comment: "Settings explanation of Reset Ranking"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        Text(
                            "App suggestions keep their own history; clear it in Settings → Applications.",
                            comment: "Settings note that Reset Ranking does not clear app activity"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if resetDone {
                    Label {
                        Text("The ranking was reset.", comment: "Settings message after Reset Ranking")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Advanced", comment: "Settings section title")
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.columnWidth)
        .fixedSize(horizontal: false, vertical: true)
        .resetRankingFlow(controls: controls, confirms: $confirmsReset, done: $resetDone, error: $resetError)
    }
}
