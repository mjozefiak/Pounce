import Foundation

/// A button of the suggestion HUD.
enum SuggestionAction: Equatable, Sendable {
    /// "Nagrywaj": the user's click starts the normal recording.
    case record
    case notNow
    /// "Nie pytaj dla tej aplikacji": mutes the app for good (`suggestMutedBundleIDs`).
    case muteApp
    /// The end-of-meeting question: stop the recording.
    case endRecording
    case keepRecording
}

/// What the suggestion HUD shows. Pure data (texts, buttons, announcements), so it is testable without a
/// window. The only content is the name of an app: no meeting title, no transcript, no audio.
enum SuggestionPrompt: Equatable, Sendable {
    /// "Wygląda na spotkanie w {aplikacja}". `bundleID` is the listed app's ID.
    case meeting(bundleID: String, appName: String)
    /// "Zakończyć nagranie?": the app stopped using the microphone and both tracks have been quiet.
    case endRecording(appName: String)

    /// The HUD disappears by itself after this long (spec: 15 s) and does nothing then.
    static let lifetime: Duration = .seconds(15)

    var title: String {
        switch self {
        case .meeting(_, let appName):
            String(
                localized: "Looks like a meeting in \(appName)",
                comment: "Meeting suggestion HUD; the placeholder is the name of the app that uses the microphone")
        case .endRecording:
            String(localized: "End the recording?", comment: "Meeting suggestion HUD: the meeting seems to be over")
        }
    }

    var actions: [SuggestionAction] {
        switch self {
        case .meeting: [.record, .notNow, .muteApp]
        case .endRecording: [.endRecording, .keepRecording]
        }
    }

    func title(for action: SuggestionAction) -> String {
        switch action {
        case .record:
            String(localized: "Record", comment: "Meeting suggestion HUD button that starts a recording")
        case .notNow:
            String(localized: "Not now", comment: "Meeting suggestion HUD button that dismisses the suggestion")
        case .muteApp:
            String(
                localized: "Don't ask for this app",
                comment: "Meeting suggestion HUD button that stops suggestions for the app for good")
        case .endRecording:
            String(localized: "End recording", comment: "Meeting HUD button that ends the recording")
        case .keepRecording:
            String(
                localized: "Keep recording",
                comment: "Meeting suggestion HUD button that keeps the recording going")
        }
    }

    /// Read by VoiceOver when the HUD appears.
    var announcement: String { title }

    var accessibilityLabel: String { title }

    var symbolName: String {
        switch self {
        case .meeting: "person.2.wave.2"
        case .endRecording: "record.circle"
        }
    }
}
