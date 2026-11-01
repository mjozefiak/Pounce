import SwiftUI

/// Settings → General: the main shortcut, launch at login and the panel's text size.
struct GeneralPane: View {
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
                    Text("Open Pounce", comment: "Settings label of the main shortcut")
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
                Text("Changes the size of text in the Pounce panel.", comment: "Settings footer for text size")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
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
