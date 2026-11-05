import Foundation
import SwiftUI
import Testing

@testable import LintelKit

/// A plugin written against the contract before the main window: it must still compile and contribute nothing
/// new (spec `2026-11-04-lintel-main-window`, step 1.1).
@MainActor final class PreMainWindowPlugin: LintelPlugin {
    static let manifest = PluginManifest(id: "premain", displayName: "Before", symbolName: "1.circle", order: 1)
    init(context: PluginContext) {}
}

/// Overrides the new contributions, to check they are reached through `any LintelPlugin`.
@MainActor final class MainWindowPlugin: LintelPlugin {
    static let manifest = PluginManifest(
        id: "mainwindow", displayName: "Main", symbolName: "2.circle", order: 2, canBeDisabled: false,
        settingsGroup: .voice, summary: "Does one thing.")
    init(context: PluginContext) {}

    var workspaceSections: [WorkspaceSection] {
        [WorkspaceSection(id: "notes", title: "Notes", symbolName: "note.text", order: 1) { AnyView(EmptyView()) }]
    }
    var settingsStatus: SettingsStatus? { SettingsStatus(level: .attention, title: "Needs a model") }
    var modelUsage: [ModelUsage] {
        [ModelUsage(packageID: "parakeet", kind: .speech, role: "Transcription", isRequired: true, isSelected: true)]
    }
}

@Suite @MainActor struct MainWindowContractTests {
    @Test func pluginDefaultsAreEmpty() {
        let plugin: any LintelPlugin = PreMainWindowPlugin(context: TestContext.make())
        #expect(plugin.workspaceSections.isEmpty)
        #expect(plugin.settingsStatus == nil)
        #expect(plugin.modelUsage.isEmpty)
    }

    @Test func overridesAreReachedThroughTheExistential() {
        let plugin: any LintelPlugin = MainWindowPlugin(context: TestContext.make())
        #expect(plugin.workspaceSections.map(\.id) == ["notes"])
        #expect(plugin.settingsStatus?.level == .attention)
        #expect(plugin.modelUsage.map(\.packageID) == ["parakeet"])
    }

    @Test func manifestDefaults() {
        let manifest = PreMainWindowPlugin.manifest
        #expect(manifest.canBeDisabled)
        #expect(manifest.settingsGroup == .lintel)
        #expect(!MainWindowPlugin.manifest.canBeDisabled)
        #expect(MainWindowPlugin.manifest.settingsGroup == .voice)
        // Owner decision 6.6b: the Features description is optional; a manifest written before it has none.
        #expect(manifest.summary == nil)
        #expect(MainWindowPlugin.manifest.summary.map { String(localized: $0) } == "Does one thing.")
        #expect(SettingsGroup.search.rawValue == "search")
        #expect(SettingsGroup(rawValue: "voice") == .voice)
    }

    @Test func contextDefaultsDoNothing() {
        let context = TestContext.make()
        #expect(context.availableCommands().isEmpty)
        context.openModels(nil)
        context.openModels("parakeet")
    }

    @Test func resultActionConfirmationDefaultsToNil() {
        let plain = ResultAction(id: "a", title: "A", symbolName: "a.circle") { _ in }
        #expect(plain.confirmation == nil)
        let confirmed = ResultAction(
            id: "d", title: "Delete", symbolName: "trash", keepsPanelOpen: true,
            confirmation: ActionConfirmation(prompt: "Press ⌃X again")
        ) { _ in }
        #expect(confirmed.confirmation != nil)
        #expect(confirmed.keepsPanelOpen)
    }

    @Test func onlySystemAudioRecordingIsUnreadable() {
        for permission in Permission.allCases {
            #expect(permission.isReadable == (permission != .systemAudioRecording))
        }
    }

    @Test func newTypesHaveEmptyDefaults() async {
        let section = WorkspaceSection(id: "s", title: "S", symbolName: "s.circle", order: 0) {
            AnyView(EmptyView())
        }
        #expect(!section.handleRoute(WorkspaceRoute(kind: "openNote", id: "x")))
        #expect(!section.handleClose())
        #expect(section.menuItems.isEmpty)
        await section.willHide()

        let status = SettingsStatus(level: .ok, title: "Ready")
        #expect(status.detail == nil)
        #expect(status.fix.isEmpty)
        #expect(status.acknowledgedPermissions.isEmpty)

        let usage = ModelUsage(packageID: "p", kind: .llm, role: "Notes", isRequired: false, isSelected: false)
        #expect(usage.chooseFolder == nil)
        #expect(await usage.isInUse() == false)
        usage.reserveRemoval()()
        #expect(ModelKind.diarization.rawValue == "diarization")

        let command = CommandInfo(title: "New Note") {}
        #expect(command.shortcut == nil)
        #expect(command.isEnabled())

        let action = SettingsStatusAction(title: "Get it", destination: .models(packageID: nil))
        guard case .models(let packageID) = action.destination else {
            Issue.record("unexpected destination")
            return
        }
        #expect(packageID == nil)
    }
}
