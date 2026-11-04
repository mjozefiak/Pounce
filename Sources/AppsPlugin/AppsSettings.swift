import Foundation
import LintelKit
import Observation
import SwiftUI

/// The app plugin's settings keys (`plugins.apps.*`, `BACKWARD_COMPATIBILITY.md` §3).
enum AppsSettingsKey {
    static let roots = "roots"
    static let spotlight = "spotlight"
    /// Bool, default `true`: learn app activity and show suggestions.
    static let suggestionsEnabled = "suggestions.enabled"
    /// [String]: bundle identifiers hidden from suggestions.
    static let suggestionsHidden = "suggestions.hidden"
    /// DEBUG only, not a contract: `bundleID=uses,…` written into an empty QA activity store.
    static let qaActivity = "qaActivity"
    /// DEBUG only, not a contract: `false` keeps the real tracker and seed from running in QA mode.
    static let qaLiveActivity = "qaLiveActivity"
}

/// The apps hidden from suggestions (`plugins.apps.suggestions.hidden`).
enum HiddenSuggestions {
    static func list(_ settings: PluginSettings) -> [String] {
        settings.stringArray(AppsSettingsKey.suggestionsHidden) ?? []
    }

    /// Adds an app; returns the new list.
    @discardableResult
    static func add(_ bundleID: String, to settings: PluginSettings) -> [String] {
        var list = list(settings)
        guard !list.contains(bundleID) else { return list }
        list.append(bundleID)
        settings.set(list, for: AppsSettingsKey.suggestionsHidden)
        return list
    }

    /// Removes an app; returns the new list.
    @discardableResult
    static func remove(_ bundleID: String, from settings: PluginSettings) -> [String] {
        let list = list(settings).filter { $0 != bundleID }
        if list.isEmpty {
            settings.removeValue(for: AppsSettingsKey.suggestionsHidden)
        } else {
            settings.set(list, for: AppsSettingsKey.suggestionsHidden)
        }
        return list
    }
}

/// State and actions behind Settings → Applications.
@MainActor
@Observable
final class AppsSettingsModel {
    @ObservationIgnored let settings: PluginSettings
    @ObservationIgnored let store: ActivityStore
    /// The folders the app index scans, for display.
    @ObservationIgnored var roots: () -> [URL] = { [] }
    /// The display name of a bundle identifier (for the hidden list).
    @ObservationIgnored var appName: (String) -> String? = { _ in nil }
    /// Called after the "Suggest Apps" toggle changed.
    @ObservationIgnored var suggestionsChanged: (Bool) -> Void = { _ in }
    /// Called after the Spotlight toggle changed.
    @ObservationIgnored var spotlightChanged: (Bool) -> Void = { _ in }
    /// Called before the activity is cleared, so a running seed stops first.
    @ObservationIgnored var willClearActivity: () -> Void = {}
    /// Called after the hidden list or the activity changed, so an open panel catches up.
    @ObservationIgnored var resultsChanged: () -> Void = {}

    private(set) var suggestionsEnabled: Bool
    private(set) var spotlightEnabled: Bool
    private(set) var hidden: [String]
    private(set) var isReadOnly: Bool
    private(set) var hasActivity: Bool

    init(settings: PluginSettings, store: ActivityStore) {
        self.settings = settings
        self.store = store
        suggestionsEnabled = settings.bool(AppsSettingsKey.suggestionsEnabled, default: true)
        spotlightEnabled = settings.bool(AppsSettingsKey.spotlight, default: true)
        hidden = HiddenSuggestions.list(settings)
        let snapshot = store.snapshot
        isReadOnly = snapshot.isReadOnly
        hasActivity = !snapshot.apps.isEmpty
    }

    /// Re-reads the settings and the store (the pane appears, the plugin changed something).
    func reload() {
        suggestionsEnabled = settings.bool(AppsSettingsKey.suggestionsEnabled, default: true)
        spotlightEnabled = settings.bool(AppsSettingsKey.spotlight, default: true)
        hidden = HiddenSuggestions.list(settings)
        let snapshot = store.snapshot
        isReadOnly = snapshot.isReadOnly
        hasActivity = !snapshot.apps.isEmpty
    }

    func setSuggestionsEnabled(_ enabled: Bool) {
        settings.set(enabled, for: AppsSettingsKey.suggestionsEnabled)
        suggestionsEnabled = enabled
        suggestionsChanged(enabled)
        resultsChanged()
    }

    func setSpotlightEnabled(_ enabled: Bool) {
        settings.set(enabled, for: AppsSettingsKey.spotlight)
        spotlightEnabled = enabled
        spotlightChanged(enabled)
    }

    /// "Clear App Activity…": empties the store; does nothing for a file from a newer version.
    func clearActivity() async {
        guard !isReadOnly else { return }
        willClearActivity()
        await store.removeAll()
        await store.close()
        reload()
        resultsChanged()
    }

    /// Hides an app from suggestions.
    func hide(_ bundleID: String) {
        guard !hidden.contains(bundleID) else { return }
        hidden = HiddenSuggestions.add(bundleID, to: settings)
        resultsChanged()
    }

    /// Shows a hidden app in suggestions again.
    func restore(_ bundleID: String) {
        hidden = HiddenSuggestions.remove(bundleID, from: settings)
        resultsChanged()
    }

    /// The name shown for a hidden app: its display name, or the bundle identifier for an app the index
    /// no longer knows.
    func displayName(of bundleID: String) -> String {
        appName(bundleID) ?? bundleID
    }
}

/// Settings → Applications: suggestions (toggle, privacy note, hidden apps, Clear App Activity…) and the
/// app index (Spotlight, searched folders).
struct AppsSettingsPane: View {
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
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.reload() }
        .confirmationDialog(
            Text("Clear the app activity?", comment: "Clear App Activity confirmation title"),
            isPresented: $confirmsClear
        ) {
            Button(role: .destructive) {
                Task { await model.clearActivity() }
            } label: {
                Text("Clear App Activity", comment: "Clear App Activity confirmation button")
            }
        } message: {
            Text(
                "Suggestions start again from the apps you use next. This cannot be undone.",
                comment: "Clear App Activity confirmation message"
            )
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
