import LintelUI
import SwiftUI

/// Settings → General: the main shortcut, launch at login, the Dock icon and the panel's text size. The main
/// window draws it on the `SettingsPane` template (prototype `set-general`, spec step 4.1); the old window keeps
/// `LegacyGeneralPane`. The "Ready" banner is the host's (`ShellPaneBanners.general`).
struct GeneralPane: View {
    let hotkeys: HotkeyService
    @Bindable var settings: AppSettings
    let launchAtLogin: any LaunchAtLoginClient

    @Environment(\.settingsHostStyle) private var hostStyle

    var body: some View {
        if hostStyle == .legacyWindow {
            LegacyGeneralPane(hotkeys: hotkeys, settings: settings, launchAtLogin: launchAtLogin)
        } else {
            GeneralPaneContent(hotkeys: hotkeys, settings: settings, launchAtLogin: launchAtLogin)
        }
    }
}

/// The main window's General pane: one Basics section, no Advanced and no Data (prototype `set-general`).
struct GeneralPaneContent: View {
    let hotkeys: HotkeyService
    @Bindable var settings: AppSettings
    let launchAtLogin: any LaunchAtLoginClient

    @Environment(\.lintelTextSize) private var textSize
    @State private var launchesAtLogin = false
    @State private var launchError: String?

    var body: some View {
        SettingsPane {
            Section {
                LabeledContent {
                    MainShortcutRecorder(hotkeys: hotkeys)
                } label: {
                    Text("Launcher shortcut", comment: "Settings → General: label of the main shortcut")
                        .font(textSize.font(.body))
                }
                if hotkeys.spotlightHoldsCommandSpace {
                    SpotlightShortcutBanner()
                        .font(textSize.font(.callout))
                }
                Toggle(isOn: launchBinding) {
                    Text("Open at login", comment: "Settings → General: launch at login switch")
                        .font(textSize.font(.body))
                    if let launchError {
                        Text(launchError)
                            .font(textSize.font(.callout))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $settings.showInDock) {
                    Text("Show icon in the Dock", comment: "Settings → General: Dock icon switch")
                        .font(textSize.font(.body))
                    Text("The Dock icon opens this window.", comment: "Settings → General: help under the Dock switch")
                        .font(textSize.font(.callout))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                Picker(selection: $settings.textSize) {
                    ForEach(TextSize.allCases) { size in
                        Text(size.accessibilityName).tag(size)
                    }
                } label: {
                    Text("Text size", comment: "Settings label of the panel text size")
                        .font(textSize.font(.body))
                }
                .pickerStyle(.menu)
            } header: {
                Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                    .font(textSize.font(.body, weight: .semibold))
            }
        }
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
