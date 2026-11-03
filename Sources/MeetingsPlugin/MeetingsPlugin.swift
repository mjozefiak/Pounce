import Foundation
import PounceKit
import SwiftUI

/// Meeting transcription and notes (spec: Transkrypcja spotkań i notatki). Step 1.2 is the skeleton and the
/// encrypted library only: no commands, no recording and **no entry in `PluginRegistry`** until the record
/// command exists (step 1.10), so nothing changes for users.
///
/// The library is `Plugins/meetings/meetings.sqlite` (SQLCipher, key in the Keychain item
/// `app.pounce.meetings`). Transcripts and notes are other people's conversations: they never reach a log, the
/// pasteboard (except an explicit copy) or `ranking.sqlite`. Settings: `plugins.meetings.*`
/// (see `MeetingsSettings.Key`). Disabled by default.
@MainActor
public final class MeetingsPlugin: PouncePlugin {
    public nonisolated static let manifest = PluginManifest(
        id: "meetings",
        displayName: LocalizedStringResource("Meetings", comment: "Plugin name of meeting transcription"),
        symbolName: "person.2.wave.2",
        order: 50,
        defaultEnabled: false
    )

    let context: PluginContext
    let settings: MeetingsSettings
    let library: MeetingsLibrary

    public init(context: PluginContext) {
        self.context = context
        let settings = MeetingsSettings(context.settings)
        self.settings = settings
        library = MeetingsLibrary(
            directory: context.storageDirectory, keychain: context.keychain, settings: settings,
            clock: context.clock,
            spool: SpoolStorage(pluginDirectory: context.storageDirectory), logger: context.logger,
            changed: context.resultsChanged)
    }

    // MARK: Lifecycle

    public func activate() async throws {
        library.open()
    }

    public func deactivate() async {
        library.close()
    }

    /// "Erase Data": removes the library's Keychain item and the plugin's folder (`meetings.sqlite`, its
    /// archives and the spool). Models live in the shared `Models/` folder and stay.
    public func eraseData() async throws {
        try library.erase()
    }

    // MARK: Contributions

    public var requiredPermissions: Set<Permission> { [.microphone, .systemAudioRecording] }
}
