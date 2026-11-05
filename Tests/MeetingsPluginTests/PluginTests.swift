import Foundation
import LintelKit
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct MeetingsPluginTests {
    @Test func theManifestIsDisabledByDefaultAndComesAfterDictation() {
        let manifest = MeetingsPlugin.manifest
        #expect(manifest.id == "meetings")
        #expect(manifest.defaultEnabled == false)
        #expect(manifest.order > 40)
    }

    @Test func thePluginContributesTheRecordCommandTheSetupAndTheSettings() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        #expect(plugin.requiredPermissions == [.microphone, .systemAudioRecording])
        #expect(plugin.commands.map(\.id) == ["meetings.record", "meetings.library"])
        #expect(plugin.panelModes.map(\.id) == ["meetings.library"])
        #expect(plugin.onboardingSteps.map(\.id) == ["meetings.setup"])
        #expect(plugin.searchSources.isEmpty)
        #expect(plugin.settingsPane() != nil)
    }

    @Test func activatingOpensTheLibraryAndDeactivatingClosesIt() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        #expect(plugin.library.status == .ready)
        #expect(plugin.library.retention.isRunning)
        await plugin.deactivate()
        await plugin.deactivate()
        #expect(plugin.library.status == .closed)
        #expect(!plugin.library.retention.isRunning)
        // Reactivating reopens the same library.
        try await plugin.activate()
        #expect(plugin.library.status == .ready)
        await plugin.deactivate()
    }

    /// A plugin whose controller records with scripted sessions and a manual clock.
    private func scriptedPlugin(
        _ harness: MeetingsHarness, behaviour: ScriptedSession.Behaviour, clock: ManualClock
    ) -> MeetingsPlugin {
        let plugin = MeetingsPlugin(context: harness.context)
        plugin.adjustControllerDependencies = { dependencies in
            dependencies.authorizer = FakeAuthorizer(.granted)
            dependencies.speechModel = { .ready(modelID: "parakeet-ultra", folder: URL(filePath: "/tmp/lintel-model")) }
            dependencies.makeSession = { _ in ScriptedSession(behaviour) }
            dependencies.clock = clock
            dependencies.shutdownTimeout = .seconds(5)
            dependencies.stateChanged = { ChangeSignal.shared.fire() }
        }
        return plugin
    }

    @Test func deactivatingWhileASessionOutlivesTheTimeoutKeepsTheLibraryOpenUntilItEnds() async throws {
        let harness = try MeetingsHarness()
        let clock = ManualClock()
        let release = Latch()
        var behaviour = ScriptedSession.Behaviour()
        behaviour.finishLatch = release
        let plugin = scriptedPlugin(harness, behaviour: behaviour, clock: clock)
        try await plugin.activate()
        let controller = try #require(plugin.controller)
        controller.start()
        await eventually("recording") { controller.phase == .recording }

        let deactivation = Task { @MainActor in await plugin.deactivate() }
        await eventually("waiting on the shutdown timeout") { clock.sleepers == 1 }
        clock.advance(by: .seconds(5))
        await deactivation.value

        // The session is still processing: the library stays open and the meeting stays registered.
        #expect(plugin.library.status == .ready)
        #expect(plugin.library.liveMeetingIDs == [7])
        #expect(plugin.activity.isActive)
        #expect(plugin.controller == nil)
        #expect(plugin.lingeringController === controller)

        release.open()
        await eventually("the library closes once the session ended") { plugin.library.status == .closed }
        #expect(plugin.library.liveMeetingIDs.isEmpty)
        #expect(!plugin.activity.isActive)
        #expect(plugin.lingeringController == nil)
    }

    @Test func reactivatingWhileASessionLingersKeepsTheLibraryOpenAfterItEnds() async throws {
        let harness = try MeetingsHarness()
        let clock = ManualClock()
        let release = Latch()
        var behaviour = ScriptedSession.Behaviour()
        behaviour.finishLatch = release
        let plugin = scriptedPlugin(harness, behaviour: behaviour, clock: clock)
        try await plugin.activate()
        let first = try #require(plugin.controller)
        first.start()
        await eventually("recording") { first.phase == .recording }
        let deactivation = Task { @MainActor in await plugin.deactivate() }
        await eventually("waiting on the shutdown timeout") { clock.sleepers == 1 }
        clock.advance(by: .seconds(5))
        await deactivation.value

        try await plugin.activate()
        release.open()
        await first.waitUntilEnded()
        await eventually("the lingering controller was released") { plugin.lingeringController == nil }
        #expect(plugin.library.status == .ready)
        await plugin.deactivate()
        #expect(plugin.library.status == .closed)
    }

    @Test func deactivatingWhileASessionEndsInTimeClosesTheLibrary() async throws {
        let harness = try MeetingsHarness()
        let plugin = scriptedPlugin(harness, behaviour: .init(), clock: ManualClock())
        try await plugin.activate()
        let controller = try #require(plugin.controller)
        controller.start()
        await eventually("recording") { controller.phase == .recording }
        await plugin.deactivate()
        #expect(plugin.library.status == .closed)
        #expect(plugin.lingeringController == nil)
        #expect(plugin.library.liveMeetingIDs.isEmpty)
    }

    @Test func eraseDataRemovesTheFolderAndTheKeychainItem() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        try plugin.library.store?.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let spool = harness.pluginDirectory.appending(path: "Spool/a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: spool.appending(path: "mic.spool"))
        #expect(harness.keychain.itemNames == ["com.lintelapp.meetings/master-key"])

        await plugin.deactivate()
        try await plugin.eraseData()

        #expect(harness.keychain.itemNames.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.pluginDirectory.path))
        // Erasing again, as the host does after it, is harmless.
        try await plugin.eraseData()
        // The next activation starts a fresh library with a new key.
        try await plugin.activate()
        #expect(plugin.library.status == .ready)
        #expect(try plugin.library.store?.meetingCount() == 0)
        await plugin.deactivate()
    }

    @Test func theLibraryNeverReachesTheRankingDatabase() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        try plugin.library.store?.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        await plugin.deactivate()
        #expect(harness.usage.callCount == 0)
    }
}

@MainActor
@Suite struct MeetingsCommandTests {
    @Test func theRecordCommandHasTheContractedShortcutAndAppearsInTheMenu() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let command = try #require(plugin.commands.first)
        #expect(command.id == "meetings.record")
        #expect(command.defaultShortcut == KeyShortcut(key: "m", modifiers: [.control, .option]))
        #expect(command.showsInMenu)
        #expect(command.panelMode == nil)
        #expect(command.onKeyEvent == nil)
        #expect(command.symbolName != nil)
        // The settings pane has its recorder now that the command exists.
        #expect(plugin.settingsPane() != nil)
    }

    @Test func theLibraryCommandOpensTheListModeWithoutAShortcut() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let command = try #require(plugin.commands.first { $0.id == "meetings.library" })
        #expect(command.panelMode == "meetings.library")
        #expect(command.defaultShortcut == nil)
        #expect(command.showsInMenu)
        #expect(command.onKeyEvent == nil)
        let mode = try #require(plugin.panelModes.first)
        #expect(mode.id == "meetings.library")
        #expect(mode.isListMode)
        #expect(mode.filters.map(\.id) == ["all", "withNotes", "needsAttention"])
        #expect(mode.makePreview != nil)
        #expect(mode.makeEmptyView != nil)
    }

    @Test func runningTheCommandBeforeActivationDoesNothing() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        await plugin.commands.first?.run()
        #expect(plugin.controller == nil)
        #expect(!plugin.activity.isActive)
    }

    @Test func activationCreatesTheControllerAndDeactivationDropsIt() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        #expect(plugin.controller?.phase == .idle)
        await plugin.deactivate()
        #expect(plugin.controller == nil)
        #expect(plugin.library.status == .closed)
        // Reactivating works, and the library is not recording anything.
        try await plugin.activate()
        #expect(plugin.controller != nil)
        await plugin.deactivate()
    }
}
