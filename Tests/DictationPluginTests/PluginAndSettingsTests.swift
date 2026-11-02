import Foundation
import PounceKit
import Synchronization
import Testing

@testable import DictationPlugin

@MainActor
@Suite struct DictationPluginLifecycleTests {
    @Test func activatingAndDeactivatingNeedsNoModelAndLeavesNothingBehind() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        try await plugin.activate()
        #expect(plugin.controller != nil)
        await plugin.deactivate()
        #expect(plugin.controller == nil)
        #expect(harness.usage.callCount == 0)
        // Nothing was created on disk until the user downloads a model.
        #expect(
            !FileManager.default.fileExists(
                atPath: harness.directory.url.appending(path: "Plugins/dictation/Models").path))
    }

    @Test func theRecordCommandRunsFromTheMenuAndTakesKeyEventsFromTheShortcut() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        let command = try #require(plugin.commands.first)
        #expect(command.showsInMenu)
        #expect(command.panelMode == nil)
        #expect(command.onKeyEvent != nil)
        // Before activation both are harmless.
        command.onKeyEvent?(.down)
        command.onKeyEvent?(.up)
        await command.run()
    }

    @Test func setupStepAndPaneExist() throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let plugin = DictationPlugin(context: harness.context)
        #expect(plugin.onboardingSteps.map(\.id) == ["dictation.setup"])
        #expect(plugin.settingsPane() != nil)
    }

    @Test func settingsReadTheirDefaultsAndStoredValues() throws {
        let harness = try DictationHarness(settings: [
            "plugins.dictation.keepWarmMinutes": .integer(3),
            "plugins.dictation.speechModelFolder": .string("/Volumes/Models/parakeet"),
            "plugins.dictation.inputDevice": .string("uid-1"),
            "plugins.dictation.restoreClipboard": .bool(false),
            "plugins.dictation.speechLanguage": .string("en"),
        ])
        defer { harness.tearDown() }
        let settings = DictationSettings(harness.context.settings)
        #expect(settings.keepWarm == .seconds(180))
        #expect(settings.speechModelFolder?.path == "/Volumes/Models/parakeet")
        #expect(settings.inputDevice == "uid-1")
        #expect(!settings.restoresClipboard)
        #expect(settings.speechLanguage == "en")
        #expect(settings.speechModelID == "parakeet-ultra")

        let fresh = try DictationHarness()
        defer { fresh.tearDown() }
        let defaults = DictationSettings(fresh.context.settings)
        #expect(defaults.keepWarm == .seconds(600))
        #expect(defaults.speechModelFolder == nil)
        #expect(defaults.restoresClipboard)
        #expect(defaults.speechLanguage == "pl")
    }
}

@MainActor
@Suite struct DictationSettingsModelTests {
    @MainActor final class Rig {
        let fixture: Fixture
        let harness: DictationHarness
        let authorizer = FakeAuthorizer()
        var pickedFolder: URL?
        var opened: [URL] = []

        init() throws {
            fixture = try Fixture()
            harness = try DictationHarness()
        }

        func model() -> DictationSettingsModel {
            DictationSettingsModel(
                package: fixture.package, manager: fixture.manager(),
                settings: DictationSettings(harness.context.settings), authorizer: authorizer,
                listDevices: { [.init(uid: "built-in", name: "MacBook Microphone")] },
                pickFolder: { [unowned self] in pickedFolder }, openURL: { [unowned self] url in opened.append(url) })
        }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func downloadingInstallsTheModelAndShowsProgress() async throws {
        let rig = try Rig()
        defer { rig.harness.tearDown() }
        rig.fixture.serve()
        let model = rig.model()
        await model.refresh()
        #expect(model.location == .missing)
        model.download()
        #expect(model.isDownloading)
        await waitUntil { model.isInstalled }
        #expect(model.isInstalled)
        #expect(model.errorMessage == nil)
        await waitUntil { !model.isDownloading }
        #expect(!model.isDownloading)
    }

    @Test func aFailedDownloadShowsAMessage() async throws {
        let rig = try Rig()
        defer { rig.harness.tearDown() }
        rig.fixture.serve(b: { _ in .body(Data(repeating: 1, count: 43)) })
        let model = rig.model()
        model.download()
        await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage?.isEmpty == false)
        await waitUntil { !model.isDownloading }
        #expect(!model.isInstalled)
    }

    @Test func aHandDownloadedFolderIsVerifiedThenRemembered() async throws {
        let rig = try Rig()
        defer { rig.harness.tearDown() }
        let folder = rig.harness.directory.url.appending(path: "mine", directoryHint: .isDirectory)
        let weights = folder.appending(path: "Model.mlmodelc/weights")
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try rig.fixture.a.write(to: weights.appending(path: "weight.bin"))
        try rig.fixture.b.write(to: folder.appending(path: "vocab.json"))
        rig.pickedFolder = folder
        let model = rig.model()
        model.chooseFolder()
        await waitUntil { model.location == .customFolder(folder) }
        #expect(model.location == .customFolder(folder))
        #expect(DictationSettings(rig.harness.context.settings).speechModelFolder == folder)

        model.useDownloadedModel()
        await waitUntil { model.location == .missing }
        #expect(DictationSettings(rig.harness.context.settings).speechModelFolder == nil)
    }

    @Test func anIncompleteFolderIsRejectedWithAMessage() async throws {
        let rig = try Rig()
        defer { rig.harness.tearDown() }
        let folder = rig.harness.directory.url.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        rig.pickedFolder = folder
        let model = rig.model()
        model.chooseFolder()
        await waitUntil { model.errorMessage != nil }
        #expect(model.errorMessage != nil)
        #expect(DictationSettings(rig.harness.context.settings).speechModelFolder == nil)
    }

    @Test func theMicrophoneIsAskedForOnlyOnTheUsersClickAndSettingsLinkToPrivacy() async throws {
        let rig = try Rig()
        defer { rig.harness.tearDown() }
        rig.authorizer.access.withLock { $0 = .notDetermined }
        let model = rig.model()
        await model.refresh()
        #expect(model.microphone == .notDetermined)
        #expect(rig.authorizer.asked.withLock { $0 } == 0)
        #expect(model.devices.map(\.name) == ["MacBook Microphone"])

        rig.authorizer.access.withLock { $0 = .granted }
        model.requestMicrophone()
        await waitUntil { model.microphone == .granted }
        #expect(rig.authorizer.asked.withLock { $0 } == 1)

        model.openMicrophoneSettings()
        model.openAccessibilitySettings()
        #expect(
            rig.opened.map(\.absoluteString) == [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            ])
    }

    @Test func choicesAreWrittenToTheSettings() async throws {
        let rig = try Rig()
        defer { rig.harness.tearDown() }
        let model = rig.model()
        model.inputDevice = "built-in"
        model.restoresClipboard = false
        let settings = DictationSettings(rig.harness.context.settings)
        #expect(settings.inputDevice == "built-in")
        #expect(!settings.restoresClipboard)
        model.inputDevice = nil
        #expect(settings.inputDevice == nil)
    }
}
