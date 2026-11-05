import LintelUI
import SwiftUI

/// Settings → Meetings → "Podpowiedzi spotkań": the switch, the apps the user muted and the extra apps.
struct MeetingsSuggestionsSection: View {
    @Bindable var model: MeetingsSettingsModel
    @State private var newApp = ""

    var body: some View {
        Section {
            Toggle(isOn: $model.suggestMeetings) {
                Text("Suggest recording when a meeting starts", comment: "Meetings settings toggle of suggestions")
            }
            if model.suggestionStatus == .unavailable {
                Label {
                    Text(
                        "Not available on this Mac: macOS does not report which apps use the microphone here.",
                        comment: "Meetings settings: the process audio API is unavailable"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                }
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            } else if model.suggestionStatus == .noData {
                Label {
                    Text(Self.noDataMessage).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "questionmark.circle").accessibilityHidden(true)
                }
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
            if !model.mutedApps.isEmpty {
                Text("Apps you muted", comment: "Meetings settings: list of apps with suggestions turned off")
                    .font(.subheadline).foregroundStyle(LintelBrand.secondaryText)
                ForEach(model.mutedApps) { app in
                    appRow(app, actionTitle: String(localized: "Ask again", comment: "Button that unmutes an app")) {
                        model.unmute(app.id)
                    }
                }
            }
            Text(
                "Other apps that count as meetings", comment: "Meetings settings: list of apps added by the user"
            )
            .font(.subheadline).foregroundStyle(LintelBrand.secondaryText)
            ForEach(model.extraApps) { app in
                appRow(app, actionTitle: String(localized: "Remove", comment: "Button that removes an added app")) {
                    model.removeExtraApp(app.id)
                }
            }
            HStack {
                TextField(
                    text: $newApp,
                    prompt: Text("e.g. com.google.Chrome", comment: "Placeholder of the bundle ID field")
                ) {
                    Text("Bundle ID", comment: "Label of the field that adds an app to the meeting suggestions")
                }
                .onSubmit(add)
                Button(action: add) {
                    Text("Add", comment: "Button that adds an app to the meeting suggestions")
                }
                .disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.extraAppError {
                Text(Self.message(error)).foregroundStyle(.orange).font(.callout)
                    .accessibilityLabel(Self.message(error))
            }
        } header: {
            Text("Meeting suggestions", comment: "Meetings settings section title")
        } footer: {
            Text(
                "Lintel only checks which app is using the microphone, never what it hears. It knows Zoom, Teams, Slack, FaceTime, Webex and Discord, and asks before recording; it never starts by itself. A browser counts only if you add it above, because a web page using the microphone can be a false alarm. Only these lists and, for a meeting you start from a suggestion, the app's ID are stored. Apps built on Safari's engine (WebKit helpers) may not be detected, and the pill cannot be operated from the keyboard; VoiceOver reads it and can press its buttons.",
                comment: "Meetings settings footer under the meeting suggestions"
            )
            .font(.callout).foregroundStyle(LintelBrand.secondaryText)
        }
    }

    /// Honest and harmless: nothing answered yet, so Lintel cannot tell whether detection works here.
    static var noDataMessage: String {
        String(
            localized:
                "Lintel cannot confirm that detection works on this Mac: no app has reported microphone use yet.",
            comment: "Meetings settings: the process audio API listens but no process has answered")
    }

    private func add() {
        if model.addExtraApp(newApp) { newApp = "" }
    }

    private func appRow(_ app: SuggestionApp, actionTitle: String, action: @escaping () -> Void) -> some View {
        LabeledContent {
            Button(actionTitle, action: action)
        } label: {
            VStack(alignment: .leading) {
                Text(app.name)
                if app.name != app.id {
                    Text(app.id).font(.caption).foregroundStyle(LintelBrand.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func message(_ error: ExtraAppError) -> String {
        switch error {
        case .invalid:
            String(
                localized: "That is not a valid bundle ID.", comment: "Error of the bundle ID field of the suggestions")
        case .duplicate:
            String(localized: "Already in the list.", comment: "Error of the bundle ID field of the suggestions")
        case .tooMany:
            String(localized: "The list is full.", comment: "Error of the bundle ID field of the suggestions")
        }
    }
}

/// Part 5 of the `meetings.setup` step: optional, with the same explanation as Settings.
struct MeetingsSuggestionsSetupPart: View {
    @Bindable var model: MeetingsSettingsModel

    var body: some View {
        // A part of the welcome page's single column (`WelcomeStepColumn`), without an icon.
        WelcomeStepItem(
            Text(
                "Optional: Lintel can suggest recording when Zoom, Teams or another meeting app starts using the microphone. It only checks which app uses the microphone, never what it hears, and never records without your click.",
                comment: "Meetings onboarding step about meeting suggestions")
        ) {
            Toggle(isOn: $model.suggestMeetings) {
                Text("Suggest recording when a meeting starts", comment: "Meetings settings toggle of suggestions")
            }
            if model.suggestionStatus == .unavailable {
                Text(
                    "Not available on this Mac: macOS does not report which apps use the microphone here.",
                    comment: "Meetings settings: the process audio API is unavailable"
                )
                .foregroundStyle(LintelBrand.statusAttention)
            } else if model.suggestionStatus == .noData {
                Text(MeetingsSuggestionsSection.noDataMessage).foregroundStyle(LintelBrand.statusAttention)
            }
        }
    }
}
