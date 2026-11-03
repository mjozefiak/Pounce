import Foundation
import PounceKit
import PounceSpeech
import SwiftUI

/// Meeting transcription and notes (spec: Transkrypcja spotkań i notatki). Registered in `PluginRegistry`
/// since step 1.10, which adds the record command (`meetings.record`, ⌃⌥M), the HUD and `MeetingController`.
/// Step 1.11 adds the command `meetings.library` and its list mode (`MeetingsPlugin+Library.swift`).
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
    let libraryActions: MeetingsLibraryActions
    /// Writes the notes of finished meetings in the background (Phase 2).
    let notes: NotesService
    private let relay = MeetingControllerRelay()
    private let hud: MeetingHUDPanel
    /// Exists while the plugin is active.
    private(set) var controller: MeetingController?
    /// A controller whose session was still processing when the plugin was switched off. It keeps the library
    /// open until the session ends (`deactivate()`).
    private(set) var lingeringController: MeetingController?
    /// Changes the controller's dependencies before it is built (tests give it fakes).
    var adjustControllerDependencies: ((inout MeetingController.Dependencies) -> Void)?

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
        let llmManager = ModelManagers.shared.manager(
            for: context.modelsDirectory.appending(path: MeetingsUI.llmDirectoryName, directoryHint: .isDirectory),
            logger: context.logger)
        let notes = NotesService(
            NotesService.Dependencies(
                library: library, settings: settings,
                modelFile: { model in
                    await llmManager.location(of: model.package).folder.flatMap { model.fileURL(in: $0) }
                },
                openSettings: context.openSettings, changed: context.resultsChanged, logger: context.logger))
        self.notes = notes
        library.onMeetingReady = { [weak notes] id in notes?.meetingBecameReady(id) }
        library.onWillClose = { [weak notes] in notes?.cancelJobs() }
        libraryActions = MeetingsLibraryActions(
            library: library, pasteboard: context.pasteboard, regenerate: { notes.regenerate($0) },
            changed: context.resultsChanged, notes: notes.board, openNotesSettings: context.openSettings)
        ui = MeetingsUI(context: context, settings: settings, library: library, activity: activity, notes: notes)
        let relay = relay
        hud = MeetingHUDPanel(onAction: { relay.controller?.perform($0) })
    }

    // MARK: Lifecycle

    public func activate() async throws {
        library.open()
        await notes.start()
        let workspace = context.workspace
        let runtime = runtime
        var dependencies = MeetingController.Dependencies(
            library: library, settings: settings, authorizer: SystemMicrophoneAuthorizer(), activity: activity,
            speechModel: { await runtime.speechLookup() }, makeSession: { runtime.makeSession($0) },
            hud: hud, clock: context.clock, openSettings: context.openSettings,
            openURL: { url in Task { try? await workspace.open(url) } }, changed: context.resultsChanged,
            logger: context.logger)
        adjustControllerDependencies?(&dependencies)
        let controller = MeetingController(dependencies)
        self.controller = controller
        relay.controller = controller
    }

    /// Switches the plugin off. A recording in progress is finished first, for at most the controller's
    /// shutdown timeout (20 s). If its session is still processing after that, **the library stays open**: the
    /// meeting is registered as live (recovery, retention and "Dokończ" leave it alone) and the library is
    /// closed by a background task as soon as the session ends, unless the plugin was activated again by then.
    /// So after `deactivate()` returns, `library.status` is `.closed` only when nothing was still running.
    public func deactivate() async {
        // A running notes job is cancelled and puts its status back before the library can close.
        await notes.shutDown()
        guard let controller else {
            library.close()
            return
        }
        let ended = await controller.shutDown()
        relay.controller = nil
        self.controller = nil
        libraryActions.closeWindows()
        if ended {
            library.close()
            return
        }
        lingeringController = controller
        Task { [weak self] in
            await controller.waitUntilEnded()
            guard let self, self.lingeringController === controller else { return }
            self.lingeringController = nil
            if self.controller == nil { self.library.close() }
        }
    }

    /// "Erase Data": removes the library's Keychain item and the plugin's folder (`meetings.sqlite`, its
    /// archives and the spool). Models live in the shared `Models/` folder and stay.
    public func eraseData() async throws {
        libraryActions.closeWindows()
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
                run: { relay.controller?.toggle() }),
            libraryCommand,
        ]
    }

    public var requiredPermissions: Set<Permission> { [.microphone, .systemAudioRecording] }
}
