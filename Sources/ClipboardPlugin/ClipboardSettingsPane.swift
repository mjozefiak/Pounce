import AppKit
import LintelKit
import LintelUI
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Clipboard. The main window draws `ClipboardPaneContent` on the `SettingsPane` template (prototype
/// `set-clipboard`, spec step 4.4); the old window keeps `LegacyClipboardSettingsPane` with its in-body history
/// banners and Try Again. The main window's banner is the host's, from `ClipboardPlugin.settingsStatus`.
struct ClipboardSettingsPane: View {
    let state: ClipboardState
    @Bindable var settings: ClipboardSettings
    let actions: ClipboardActions
    let recorder: AnyView
    let clearHistory: @MainActor () async -> Bool

    @Environment(\.settingsHostStyle) private var hostStyle

    static let confirmation = DestructiveConfirmation(
        prompt: LocalizedStringResource("Clear the clipboard history?", comment: "Clear History confirmation title"),
        detail: LocalizedStringResource(
            "All entries are deleted. This can’t be undone.", comment: "Clear History confirmation message"),
        confirmTitle: LocalizedStringResource("Clear History", comment: "Clear History confirmation button"))

    var body: some View {
        Group {
            if hostStyle == .legacyWindow {
                LegacyClipboardSettingsPane(
                    state: state, settings: settings, actions: actions, recorder: recorder, clearHistory: clearHistory)
            } else {
                ClipboardPaneContent(state: state, settings: settings, recorder: recorder, clearHistory: clearHistory)
            }
        }
        // The banners read pasteboard access; it is re-read here, not while the banner draws.
        .onAppear { actions.recheck() }
    }
}

/// The main window's Clipboard pane (prototype `set-clipboard`): Basics (Keep clipboard history, Keep for, At
/// most, the shortcut), Advanced (the ignored apps) and Data (the history with Clear History…). The history's
/// state (ready, paused, keychain, pasteboard access, reset notice) is the host's banner; while the key cannot
/// be read the Basics are dimmed, as in `set-error`.
struct ClipboardPaneContent: View {
    let state: ClipboardState
    @Bindable var settings: ClipboardSettings
    let recorder: AnyView
    let clearHistory: @MainActor () async -> Bool

    @Environment(\.lintelTextSize) private var textSize
    @State private var confirmsClear = false
    @State private var clearFailed = false

    private var isUnavailable: Bool {
        state.availability == .keychainLocked || state.availability == .keychainUnavailable
    }

    var body: some View {
        SettingsPane {
            Section {
                Toggle(isOn: recordingBinding) {
                    Text(
                        "Keep clipboard history",
                        comment: "Settings → Clipboard: switch that pauses or resumes recording"
                    )
                    .font(textSize.font(.body))
                }
                .toggleStyle(.switch)
                Picker(selection: daysBinding) {
                    ForEach(RetentionPolicy.dayChoices, id: \.self) { days in
                        Text(ClipboardSettingsText.days(days)).tag(days)
                    }
                } label: {
                    Text("Keep for", comment: "Dictation settings label of the retention period")
                        .font(textSize.font(.body))
                }
                .pickerStyle(.menu)
                Picker(selection: countBinding) {
                    ForEach(RetentionPolicy.countChoices, id: \.self) { count in
                        Text(ClipboardSettingsText.maximum(count)).tag(count)
                    }
                } label: {
                    Text(
                        LocalizedStringResource(
                            "At most (clipboard)", defaultValue: "At most",
                            comment: "Settings → Clipboard: label of the maximum number of entries")
                    )
                    .font(textSize.font(.body))
                }
                .pickerStyle(.menu)
                LabeledContent {
                    recorder
                } label: {
                    Text("Shortcut", comment: "Settings section title")
                        .font(textSize.font(.body))
                }
            } header: {
                Text("Basics", comment: "Settings pane section title: the main settings of a pane")
                    .settingsSectionHeader()
            }
            .disabled(isUnavailable)
            .opacity(isUnavailable ? 0.5 : 1)
        } advanced: {
            IgnoredAppsRows(settings: settings)
            SettingsFooter(
                LocalizedStringResource(
                    "Nothing copied in these apps is recorded.", comment: "Settings footer of the ignored apps"))
            SettingsFooter(
                LocalizedStringResource(
                    "Entries are encrypted and stay on this Mac. Concealed content, such as passwords, is never recorded.",
                    comment: "Settings footer of clipboard recording"))
        } data: {
            LabeledContent {
                Button(role: .destructive) {
                    confirmsClear = true
                } label: {
                    Text("Clear History…", comment: "Button that deletes the whole clipboard history")
                        .font(textSize.font(.body))
                }
                .lintelDestructiveButton()
                .disabled(state.availability != .ready)
            } label: {
                Text("History", comment: "Settings section title")
                    .font(textSize.font(.body))
                Text("Encrypted on this Mac.", comment: "Settings → Clipboard: help under History in Data")
                    .font(textSize.font(.callout))
                    .foregroundStyle(.secondary)
            }
            if clearFailed {
                Text("The history could not be cleared.", comment: "Error after Clear History failed")
                    .font(textSize.font(.callout))
                    .foregroundStyle(LintelBrand.statusError)
            }
        }
        .destructiveConfirmation(isPresented: $confirmsClear, ClipboardSettingsPane.confirmation) {
            Task {
                clearFailed = !(await clearHistory())
            }
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
}

/// The ignored apps, each with Remove, then Add App… and Restore Defaults.
struct IgnoredAppsRows: View {
    @Bindable var settings: ClipboardSettings

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        Text("Ignored apps", comment: "Settings section title")
            .font(textSize.font(.body))
        ForEach(settings.ignoredApps, id: \.self) { bundleID in
            // Looked up once per row: the label and the Remove button's accessibility label share it.
            let url = IgnoredAppLabel.installedURL(bundleID, looksUp: settings.looksUpInstalledApps)
            let name = IgnoredAppLabel.name(bundleID, url: url)
            LabeledContent {
                Button {
                    settings.removeIgnoredApp(bundleID)
                } label: {
                    Text("Remove", comment: "Button that removes the selected item from a list")
                        .font(textSize.font(.body))
                }
                .accessibilityLabel(
                    Text(
                        "Remove \(name)",
                        comment: "Accessibility label of the button that removes a list item"))
            } label: {
                IgnoredAppLabel(bundleID: bundleID, url: url, name: name)
            }
        }
        HStack {
            Button(action: addApp) {
                Text("Add App…", comment: "Button that adds an app to the ignored apps")
                    .font(textSize.font(.body))
            }
            Spacer()
            Button {
                settings.restoreDefaultIgnoredApps()
            } label: {
                Text("Restore Defaults", comment: "Button that restores the default ignored apps")
                    .font(textSize.font(.body))
            }
            .disabled(settings.usesDefaultIgnoredApps)
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

/// An ignored app in the main window: its name and icon when it is installed, else its known name or the bundle
/// identifier. In QA mode (`looksUp == false`) installed apps are never looked up.
struct IgnoredAppLabel: View {
    let bundleID: String
    /// The installed app, if it was looked up and found.
    let url: URL?
    let name: String

    @Environment(\.lintelTextSize) private var textSize

    var body: some View {
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 18 * textSize.scale, height: 18 * textSize.scale)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "app.dashed")
                    .font(textSize.font(.body))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(textSize.font(.body))
                Text(verbatim: bundleID)
                    .font(textSize.font(.caption1))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    /// The installed app of `bundleID`, looked up only when allowed.
    static func installedURL(_ bundleID: String, looksUp: Bool) -> URL? {
        looksUp ? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) : nil
    }

    /// The name shown for `bundleID`: the installed app's, else its known name, else the bundle identifier.
    static func name(_ bundleID: String, url: URL?) -> String {
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

    /// "1000 entries": a choice of the maximum number of entries (main window), with the plural rules of the
    /// language and, as in the old window, without a grouping separator (`%lld` is not grouped).
    static func maximum(_ count: Int) -> String {
        String(
            localized: "%lld entries (clipboard maximum)", defaultValue: "\(count) entries",
            comment: "Settings → Clipboard: a choice of the maximum number of entries")
    }
}
