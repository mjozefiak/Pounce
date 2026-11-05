import Foundation
import LintelKit
import LintelSpeech
import LintelUI

/// The main window's banner of Settings → Meetings (prototype `set-meetings`, spec step 5.2).
extension MeetingsPlugin {
    /// The shell reads it only while the plugin is active and while the view draws, so it only reads: the speech
    /// model's place and the microphone are re-read on activation, when the pane appears and when Lintel becomes
    /// the active app, and a change signals `resultsChanged`. A denied microphone is listed by the shell's
    /// derivation and counted in the title's number (`ThingsToDo`); System Audio Recording cannot be read and is
    /// never counted (spec 2.2).
    public var settingsStatus: SettingsStatus? {
        let model = ui.model
        let library = library
        let changed = context.resultsChanged
        let denied = ThingsToDo.deniedPermissions(
            requiredPermissions, countedByPlugin: model.microphone == .notDetermined ? [.microphone] : [],
            reader: context.permissions)
        return Self.settingsStatus(
            location: model.speech.location, microphone: model.microphone, library: library.status,
            modelTitle: model.speech.package.title, packageID: model.speech.package.id, deniedPermissions: denied,
            allowMicrophone: { await model.requestMicrophoneAccess() },
            retryLibrary: {
                library.open()
                changed()
            })
    }

    /// The banner ids of the plugin's own actions.
    nonisolated static let allowMicrophoneActionID = "allowMicrophone"
    nonisolated static let retryLibraryActionID = "retry"

    /// Most important first: a library that cannot be opened (nothing can be recorded; Try Again, nothing is
    /// deleted), then what recording needs: a microphone macOS has not asked about yet and the speech model
    /// ("N things to do" with one "Fix Next" button, as in the prototype). The speaker model is optional and not
    /// counted: finishing falls back to one speaker without it. `deniedPermissions` is how many denied required
    /// permissions the shell adds to the detail; the number in the title counts them too.
    static func settingsStatus(
        location: ModelLocation,
        microphone: MicrophoneAccess,
        library: MeetingsLibrary.Status,
        modelTitle: String,
        packageID: String,
        deniedPermissions: Int = 0,
        allowMicrophone: @escaping @MainActor @Sendable () async -> Void,
        retryLibrary: @escaping @MainActor @Sendable () async -> Void
    ) -> SettingsStatus? {
        if let paused = pausedStatus(library, retry: retryLibrary) { return paused }
        let needsModel = location.folder == nil
        let needsMicrophone = microphone == .notDetermined
        let getModel = SettingsStatusAction(
            title: LocalizedStringResource(
                "Get It in Models", comment: "Settings banner button: opens the Models pane on the missing model"),
            destination: .models(packageID: packageID))
        let title = ThingsToDo.title((needsModel ? 1 : 0) + (needsMicrophone ? 1 : 0) + deniedPermissions)
        switch (needsModel, needsMicrophone) {
        case (true, true):
            // One button: the microphone first (it asks only on this click), then the banner offers the model.
            return SettingsStatus(
                level: .attention, title: title,
                detail: LocalizedStringResource(
                    "Allow the microphone and get the speech model.",
                    comment: "Settings banner detail: the microphone was not asked yet and the speech model is missing"
                ),
                fix: [
                    SettingsStatusAction(
                        title: LocalizedStringResource(
                            "Fix Next", comment: "Settings banner button: fixes the first of several things to do"),
                        destination: .plugin(id: allowMicrophoneActionID, perform: allowMicrophone))
                ])
        case (true, false):
            let detail: LocalizedStringResource
            if case .customFolderUnavailable = location {
                detail = LocalizedStringResource(
                    "The speech model’s folder isn’t available.",
                    comment: "Settings → Meetings banner detail: the folder the user chose for the speech model is gone"
                )
            } else {
                detail = LocalizedStringResource(
                    "The speech model isn’t installed.", comment: "Settings banner detail: the speech model is missing")
            }
            return SettingsStatus(level: .attention, title: title, detail: detail, fix: [getModel])
        case (false, true):
            return SettingsStatus(
                level: .attention, title: title,
                detail: LocalizedStringResource(
                    "Allow the microphone so Lintel can hear the meeting.",
                    comment: "Settings → Meetings banner detail: macOS has not asked for the microphone yet"),
                fix: [
                    SettingsStatusAction(
                        title: LocalizedStringResource(
                            "Allow Microphone", comment: "Button that asks for microphone access"),
                        destination: .plugin(id: allowMicrophoneActionID, perform: allowMicrophone))
                ])
        case (false, false):
            return SettingsStatus(
                level: .ok,
                title: LocalizedStringResource("Ready", comment: "Settings banner level, spoken"),
                detail: LocalizedStringResource(
                    "Speech model: \(modelTitle).",
                    comment: "Settings → Meetings banner detail when recording is ready: the speech model's name"))
        }
    }

    /// The library is locked or broken: recording cannot start, nothing was deleted.
    private static func pausedStatus(
        _ library: MeetingsLibrary.Status, retry: @escaping @MainActor @Sendable () async -> Void
    ) -> SettingsStatus? {
        let detail: LocalizedStringResource
        switch library {
        case .unavailable:
            detail = LocalizedStringResource(
                "Lintel can’t read the library’s key. Nothing was deleted.",
                comment: "Settings → Meetings banner detail when the library key cannot be read")
        case .failed:
            detail = LocalizedStringResource(
                "The library couldn’t be opened. Nothing was deleted.",
                comment: "Settings → Meetings banner detail when the library database cannot be opened")
        case .closed, .ready:
            return nil
        }
        return SettingsStatus(
            level: .error,
            title: LocalizedStringResource(
                "Meetings are paused", comment: "Settings → Meetings banner when the library cannot be opened"),
            detail: detail,
            fix: [
                SettingsStatusAction(
                    title: LocalizedStringResource(
                        "Try Again (meetings library)", defaultValue: "Try Again",
                        comment: "Settings → Meetings banner button that opens the library again"),
                    destination: .plugin(id: retryLibraryActionID, perform: retry))
            ])
    }
}
