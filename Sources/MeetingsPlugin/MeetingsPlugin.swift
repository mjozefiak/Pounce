import Foundation
import PounceKit
import PounceSpeech
import SwiftUI

/// Meeting transcription and notes (spec: Transkrypcja spotkań i notatki). Registered in `PluginRegistry`
/// since step 1.10, which adds the record command (`meetings.record`, ⌃⌥M), the HUD and `MeetingController`.
/// The command `meetings.library` and its list mode come with step 1.11.
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
    /// True while a session records or processes; the session owner (step 1.10) calls `begin()` / `end()`.
    let activity = MeetingActivity()
    let ui: MeetingsUI
    let runtime: MeetingsRuntime
    private let relay = MeetingControllerRelay()
    private let hud: MeetingHUDPanel
    /// Exists while the plugin is active.
    private(set) var controller: MeetingController?

    public init(context: PluginContext) {
        self.context = context
        let settings = MeetingsSettings(context.settings)
        self.settings = settings
        let runtime = MeetingsRuntime(context: context, settings: settings)
        self.runtime = runtime
        library = MeetingsLibrary(
            directory: context.storageDirectory, keychain: context.keychain, settings: settings,
            clock: context.clock,
            spool: SpoolStorage(pluginDirectory: context.storageDirectory),
            makeResumer: { store, keys, spool in runtime.makeResumer(store: store, keys: keys, spool: spool) },
            logger: context.logger, changed: context.resultsChanged)
        ui = MeetingsUI(context: context, settings: settings, library: library, activity: activity)
        let relay = relay
        hud = MeetingHUDPanel(onAction: { relay.controller?.perform($0) })
    }

    // MARK: Lifecycle

    public func activate() async throws {
        library.open()
        let workspace = context.workspace
        let runtime = runtime
        let controller = MeetingController(
            .init(
                library: library, settings: settings, authorizer: SystemMicrophoneAuthorizer(), activity: activity,
                speechModel: { await runtime.speechLookup() }, makeSession: { runtime.makeSession($0) },
                hud: hud, clock: context.clock, openSettings: context.openSettings,
                openURL: { url in Task { try? await workspace.open(url) } }, changed: context.resultsChanged,
                logger: context.logger))
        self.controller = controller
        relay.controller = controller
    }

    /// Sessions that are recording or finalizing must be stopped (or stay registered through
    /// `MeetingsLibrary.registerLive`) **before** this runs: closing the library does not end them, and
    /// registered meetings are the only ones a later `activate()` leaves alone.
    public func deactivate() async {
        // A recording in progress is finished first (bounded), then the library closes.
        await controller?.shutDown()
        relay.controller = nil
        controller = nil
        library.close()
    }

    /// "Erase Data": removes the library's Keychain item and the plugin's folder (`meetings.sqlite`, its
    /// archives and the spool). Models live in the shared `Models/` folder and stay.
    public func eraseData() async throws {
        try library.erase()
    }

    // MARK: Contributions

    public var commands: [PluginCommand] {
        let relay = relay
        return [
            PluginCommand(
                id: MeetingsUI.recordCommandID,
                title: LocalizedStringResource(
                    "Record Meeting / Stop Recording",
                    comment: "Menu item and command that starts or ends a meeting recording"),
                symbolName: "record.circle",
                defaultShortcut: KeyShortcut(key: "m", modifiers: [.control, .option]),
                run: { relay.controller?.toggle() })
        ]
    }

    public var requiredPermissions: Set<Permission> { [.microphone, .systemAudioRecording] }
}
