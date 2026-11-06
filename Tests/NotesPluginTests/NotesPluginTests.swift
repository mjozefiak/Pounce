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

    @Test func fixturesAppearOnlyWhenTheQAKeyIsOn() async {
        let off = NotesPlugin(context: makeContext())
        await off.workspace.refresh()
        #expect(off.workspace.rows.isEmpty)
        let settings = MemorySettings()
        PluginSettings(pluginID: "notes", store: settings).set(true, for: NotesSettingsKey.qaFixtures)
        let on = NotesPlugin(context: makeContext(settings: settings))
        await on.workspace.refresh()
        #expect(on.workspace.rows.count == NotesQAFixtures.summaries().count)
        #expect(on.workspace.rows.count > 0)
    }

    @Test func fixtureKeysBelongToTheirOwnersAndAreUnique() {
        let summaries = NotesQAFixtures.summaries()
        let keys = summaries.map(\.id)
        #expect(Set(keys).count == keys.count)
        for summary in summaries {
            let owner: PluginID = summary.kind == .meeting ? "meetings" : "dictation"
            #expect(summary.kind == .meeting || summary.kind == .dictation)
            #expect(summary.id.pluginID == owner)
            #expect(NotesQAFixtures.content(for: summary.id) != nil)
        }
    }

    @Test func theSectionHandlesAnOpenNoteRouteAndClosesATabBeforeTheWindow() throws {
        let plugin = NotesPlugin(context: makeContext())
        let section = try #require(plugin.workspaceSections.first)
        #expect(!section.handleRoute(WorkspaceRoute(kind: "openModels", id: "x")))
        #expect(!section.handleClose())
        #expect(section.handleRoute(NoteRoute.route(for: NotesQAFixtures.meetingID)))
        #expect(section.handleRoute(NoteRoute.route(for: NotesQAFixtures.dictationID)))
        #expect(plugin.workspace.tabs.tabs.count == 2)
        #expect(section.handleClose())
        #expect(!section.handleClose())
    }
}
