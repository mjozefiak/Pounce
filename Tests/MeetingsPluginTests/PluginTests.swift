import Foundation
import PounceKit
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
        // `meetings.library` and the list mode come with step 1.11.
        #expect(plugin.commands.map(\.id) == ["meetings.record"])
        #expect(plugin.panelModes.isEmpty)
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

    @Test func eraseDataRemovesTheFolderAndTheKeychainItem() async throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        try await plugin.activate()
        try plugin.library.store?.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        let spool = harness.pluginDirectory.appending(path: "Spool/a", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: spool.appending(path: "mic.spool"))
        #expect(harness.keychain.itemNames == ["app.pounce.meetings/master-key"])

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
