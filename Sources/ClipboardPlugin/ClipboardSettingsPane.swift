import AppKit
import PounceKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Clipboard: the shortcut, recording, retention, ignored apps and Clear History.
struct ClipboardSettingsPane: View {
    let state: ClipboardState
    @Bindable var settings: ClipboardSettings
    let actions: ClipboardActions
    let recorder: AnyView
    let clearHistory: @MainActor () async -> Bool

    @State private var confirmsClear = false
    @State private var clearFailed = false
    @State private var selectedApp: String?

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    recorder
                } label: {
                    Text("Open Clipboard History", comment: "Settings label of the clipboard history shortcut")
                }
            } header: {
                Text("Shortcut", comment: "Settings section title")
            }

            Section {
                Toggle(isOn: recordingBinding) {
                    Text("Record clipboard history", comment: "Settings toggle that pauses or resumes recording")
                }
                ForEach(ClipboardBanner.banners(for: state).filter { $0 != .paused }, id: \.self) { banner in
                    ClipboardBannerRow(banner: banner, actions: actions)
                }
            } footer: {
                Text(
                    "Entries are encrypted and stay on this Mac. Concealed content, such as passwords, is never recorded.",
                    comment: "Settings footer of clipboard recording"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: daysBinding) {
                    ForEach(RetentionPolicy.dayChoices, id: \.self) { days in
                        Text(ClipboardSettingsText.days(days)).tag(days)
                    }
                } label: {
                    Text("Keep entries for", comment: "Settings label of the clipboard retention period")
                }
                Picker(selection: countBinding) {
                    ForEach(RetentionPolicy.countChoices, id: \.self) { count in
                        Text(count, format: .number.grouping(.never)).tag(count)
                    }
                } label: {
                    Text("Keep at most", comment: "Settings label of the maximum number of clipboard entries")
                }
            } header: {
                Text("History", comment: "Settings section title")
            } footer: {
                Text(
                    "Older entries are deleted automatically.",
                    comment: "Settings footer of clipboard retention"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                List(selection: $selectedApp) {
                    ForEach(settings.ignoredApps, id: \.self) { bundleID in
                        IgnoredAppRow(bundleID: bundleID)
                            .tag(bundleID)
                    }
                }
                .frame(minHeight: 120)
                .accessibilityLabel(Text("Ignored apps", comment: "Settings section title"))
                HStack {
                    Button {
                        addApp()
                    } label: {
                        Text("Add App…", comment: "Button that adds an app to the ignored apps")
                    }
                    Button {
                        if let selectedApp {
                            settings.removeIgnoredApp(selectedApp)
                            self.selectedApp = nil
                        }
                    } label: {
                        Text("Remove", comment: "Button that removes the selected ignored app")
                    }
                    .disabled(selectedApp == nil)
                    Spacer()
                    Button {
                        settings.restoreDefaultIgnoredApps()
                    } label: {
                        Text("Restore Defaults", comment: "Button that restores the default ignored apps")
                    }
                    .disabled(settings.usesDefaultIgnoredApps)
                }
            } header: {
                Text("Ignored apps", comment: "Settings section title")
            } footer: {
                Text(
                    "Nothing copied in these apps is recorded.",
                    comment: "Settings footer of the ignored apps"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Text("Clear History…", comment: "Button that deletes the whole clipboard history")
                    }
                    .disabled(state.availability != .ready)
                } label: {
                    Text(ClipboardSettingsText.entries(state.entryCount))
                }
                if clearFailed {
                    Text("The history could not be cleared.", comment: "Error after Clear History failed")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog(
            Text("Clear the clipboard history?", comment: "Clear History confirmation title"),
            isPresented: $confirmsClear
        ) {
            Button(role: .destructive) {
                Task {
                    clearFailed = !(await clearHistory())
                }
            } label: {
                Text("Clear History", comment: "Clear History confirmation button")
            }
        } message: {
            Text("All entries are deleted. This cannot be undone.", comment: "Clear History confirmation message")
        }
    }

    private var recordingBinding: Binding<Bool> {
        Binding {
            !settings.isPaused
        } set: {
            settings.setPaused(!$0)
        }
    }

    private var daysBinding: Binding<Int> {
        Binding {
            settings.retention.days
        } set: {
            settings.setRetentionDays($0)
        }
    }

    private var countBinding: Binding<Int> {
        Binding {
            settings.retention.maximumCount
        } set: {
            settings.setMaximumEntries($0)
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(filePath: "/Applications")
        panel.prompt = String(localized: "Ignore", comment: "Open panel button that adds apps to the ignored apps")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier {
                settings.addIgnoredApp(bundleID)
            }
        }
    }
}

/// An ignored app: its name and icon when it is installed, else the bundle identifier.
struct IgnoredAppRow: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
            Text(name(url))
            Spacer()
            Text(bundleID)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func name(_ url: URL?) -> String {
        if let url {
            return FileManager.default.displayName(atPath: url.path(percentEncoded: false))
                .replacingOccurrences(of: ".app", with: "")
        }
        return ClipboardSettings.knownAppNames[bundleID] ?? bundleID
    }
}

enum ClipboardSettingsText {
    static func days(_ days: Int) -> String {
        String(localized: "\(days) days", comment: "Clipboard retention choice, a number of days")
    }

    static func entries(_ count: Int) -> String {
        String(localized: "\(count) entries in the history", comment: "Number of clipboard entries in the settings")
    }
}
