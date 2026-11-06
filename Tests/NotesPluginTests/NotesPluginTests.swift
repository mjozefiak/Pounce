import Foundation
import LintelKit
import SwiftUI
import Testing

@testable import NotesPlugin

@Suite @MainActor struct NotesPluginTests {
    @Test func manifestValues() {
        let manifest = NotesPlugin.manifest
        #expect(manifest.id == "notes")
        #expect(manifest.order == 5)
        #expect(manifest.defaultEnabled)
        #expect(!manifest.canBeDisabled)
        #expect(manifest.settingsGroup == .lintel)
    }

    @Test func theSectionStubIsRegisteredThroughWorkspaceSections() throws {
        let plugin: any LintelPlugin = NotesPlugin(context: makeContext())
        let section = try #require(plugin.workspaceSections.first)
        #expect(plugin.workspaceSections.count == 1)
        #expect(section.id == "notes")
        #expect(section.symbolName == "note.text")
        #expect(section.order == NotesPlugin.manifest.order)
        _ = section.makeView()
    }

    @Test func theOtherContributionsStayEmpty() {
        let plugin: any LintelPlugin = NotesPlugin(context: makeContext())
        #expect(plugin.searchSources.isEmpty)
        #expect(plugin.commands.isEmpty)
        #expect(plugin.panelModes.isEmpty)
        #expect(plugin.onboardingSteps.isEmpty)
        #expect(plugin.requiredPermissions.isEmpty)
        #expect(plugin.noteSources.isEmpty)
        #expect(plugin.modelUsage.isEmpty)
    }

    @Test func activationAndDeactivationTouchNeitherFilesNorKeychain() async throws {
        let storage = FileManager.default.temporaryDirectory.appending(
            path: "lintel-notes-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let keychain = CountingKeychain()
        let plugin = NotesPlugin(context: makeContext(storage: storage, keychain: keychain))
        try await plugin.activate()
        _ = plugin.workspaceSections
        await plugin.deactivate()
        try await plugin.activate()
        await plugin.deactivate()
        #expect(keychain.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.path))
        try await plugin.eraseData()
        #expect(keychain.calls == 0)
    }

    @Test func fixturesAppearOnlyWhenTheQAKeyIsOn() {
        let off = NotesPlugin(context: makeContext())
        #expect(off.qaFixtures.count == 0)
        let settings = MemorySettings()
        let on = NotesPlugin(context: makeContext(settings: settings))
        PluginSettings(pluginID: "notes", store: settings).set(true, for: NotesSettingsKey.qaFixtures)
        #expect(on.qaFixtures.count == NotesQAFixtures.summaries.count)
        #expect(on.qaFixtures.count > 0)
    }

    @Test func fixtureKeysBelongToTheirOwnersAndAreUnique() {
        let keys = NotesQAFixtures.summaries.map(\.id)
        #expect(Set(keys).count == keys.count)
        let owners = Dictionary(uniqueKeysWithValues: NotesQAFixtures.summaries.map { ($0.kind, $0.id.pluginID) })
        #expect(owners == [.meeting: "meetings", .dictation: "dictation", .manual: "notes"])
    }
}
