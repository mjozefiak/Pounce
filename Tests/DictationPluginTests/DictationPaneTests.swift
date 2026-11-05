import AppKit
import Foundation
import LintelKit
import LintelUI
import SwiftUI
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// Spec `2026-11-04-lintel-main-window`, step 5.1: the main window's Dictation pane on the `SettingsPane` template
/// (prototype `set-dictation`) and the plugin's own banner.
@MainActor
@Suite struct DictationPaneTests {
    /// Counts the calls of a banner action.
    @MainActor final class Calls {
        var count = 0
    }

    private static let root: URL = {
        var url = URL(filePath: #filePath).deletingLastPathComponent()
        while url.path != "/", !FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) {
            url = url.deletingLastPathComponent()
        }
        return url
    }()

    private static func paneSource() throws -> String {
        try String(
            contentsOf: root.appending(path: "Sources/DictationPlugin/DictationSettingsPane.swift"), encoding: .utf8)
    }

    private func content(_ rig: DictationSettingsModelTests.Rig) -> DictationPaneContent {
        let settings = DictationSettings(rig.harness.context.settings)
        return DictationPaneContent(
            model: rig.model(),
            formatting: FormattingSettingsModel(
                settings: settings, transport: ScriptedTransport(.failure(.cannotConnectToHost))),
            history: HistorySettingsModel(
                settings: settings, history: DictationPlugin(context: rig.harness.context).history),
            recorder: AnyView(EmptyView()), isActive: false)
    }

    // MARK: Structure

    @Test func theMainWindowPaneUsesTheTemplateAndNoModelCards() throws {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        let types = ViewTree.typeNames(in: content(rig).body)
        #expect(types.contains("SettingsPane"))
        #expect(types.contains("ModelChoiceRow"))
        for legacy in ["SpeechModelCard", "MicrophoneRows", "BuiltInModelRows", "LegacyDictationSettingsPane"] {
            #expect(!types.contains(legacy), "\(legacy)")
        }
    }

    @Test func theRowsFollowThePrototypeOrder() throws {
        let source = try Self.paneSource()
        let rows = [
            "\"Basics\"", "\"Dictate\"", "\"Speech model\"", "\"Clean up text\"", "\"Input device\"",
            "\"Restore the clipboard after pasting\"", "\"Keep a history\"", "\"Keep for\"", "\"At most\"",
            "\"Clear History…\"",
        ]
        var position = source.startIndex
        for row in rows {
            let found = try #require(source.range(of: row, range: position..<source.endIndex), "\(row) out of order")
            position = found.upperBound
        }
        // The Data section is titled History, as in the prototype.
        #expect(source.contains("dataTitle: LocalizedStringResource(\"History\""))
    }

    @Test func thereIsNoAutomaticLanguageRow() throws {
        let source = try Self.paneSource()
        #expect(!source.contains("\"Automatic\""))
        // The language is offered only for Whisper, which listens for one language.
        #expect(source.contains("if model.usesPinnedLanguage {"))
    }

    @Test func theMainWindowPaneRendersAtEveryTextSize() throws {
        let rig = try DictationSettingsModelTests.Rig()
        defer { rig.harness.tearDown() }
        for size in [TextSize.small, .extraLarge] {
            let renderer = ImageRenderer(
                content: content(rig).lintelTextSize(size).environment(\.settingsHostStyle, .mainWindow)
                    .frame(width: 600, height: 900))
            #expect(renderer.nsImage != nil)
        }
    }

    // MARK: Banner

    private func status(
        location: ModelLocation = .installed(URL(filePath: "/tmp/model")),
        microphone: MicrophoneAccess = .granted,
        history: DictationHistory.Status = .ready,
        allow: @escaping @MainActor @Sendable () async -> Void = {},
        retry: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> SettingsStatus? {
        DictationPlugin.settingsStatus(
            location: location, microphone: microphone, history: history, modelTitle: "Parakeet Ultra",
            packageID: ModelCatalog.parakeetUltra.id, allowMicrophone: allow, retryHistory: retry)
    }

    @Test func aMissingModelNeedsAttentionWithGetItInModels() throws {
        for location in [ModelLocation.missing, .partial(bytes: 10)] {
            let banner = try #require(status(location: location))
            #expect(banner.level == .attention)
            #expect(banner.title.key == "1 thing to do")
            #expect(banner.detail?.key == "The speech model isn’t installed.")
            #expect(banner.fix.count == 1)
            #expect(banner.fix.first?.title.key == "Get It in Models")
            guard case .models(let packageID) = banner.fix.first?.destination else {
                Issue.record("not a Models action")
                return
            }
            #expect(packageID == ModelCatalog.parakeetUltra.id)
        }
    }

    @Test func aMissingFolderSaysSo() throws {
        let banner = try #require(status(location: .customFolderUnavailable(URL(filePath: "/Volumes/Gone"))))
        #expect(banner.level == .attention)
        #expect(banner.detail?.key == "The speech model’s folder isn’t available.")
    }

    @Test func anInstalledModelIsReady() throws {
        for location in [ModelLocation.installed(URL(filePath: "/a")), .customFolder(URL(filePath: "/b"))] {
            let banner = try #require(status(location: location))
            #expect(banner.level == .ok)
            #expect(banner.title.key == "Ready")
            #expect(banner.fix.isEmpty)
        }
    }

    @Test func aDeniedMicrophoneIsLeftToTheShell() throws {
        // The shell's derivation adds "Microphone: not allowed" with Open System Settings.
        let banner = try #require(status(microphone: .denied))
        #expect(banner.level == .ok)
        #expect(banner.acknowledgedPermissions.isEmpty)
    }

    @Test func anUnaskedMicrophoneOffersAllowMicrophoneThatRunsOnlyOnTheClick() async throws {
        let asked = Calls()
        let read = status(microphone: .notDetermined, allow: { asked.count += 1 })
        let banner = try #require(read)
        #expect(banner.level == .attention)
        #expect(banner.title.key == "1 thing to do")
        let action = try #require(banner.fix.first)
        #expect(action.title.key == "Allow Microphone")
        guard case .plugin(let id, let perform) = action.destination else {
            Issue.record("not a plugin action")
            return
        }
        #expect(id == "allowMicrophone")
        #expect(asked.count == 0)
        await perform()
        #expect(asked.count == 1)
    }

    @Test func bothMissingAreTwoThingsToDo() throws {
        let banner = try #require(status(location: .missing, microphone: .notDetermined))
        #expect(banner.level == .attention)
        #expect(banner.title.key == "2 things to do")
        #expect(banner.fix.map(\.title.key) == ["Allow Microphone", "Get It in Models"])
    }

    @Test func anUnreadableHistoryOffersTryAgain() async throws {
        let retried = Calls()
        for history in [DictationHistory.Status.unavailable(.denied), .failed] {
            let read = status(history: history, retry: { retried.count += 1 })
            let banner = try #require(read)
            #expect(banner.level == .attention)
            #expect(banner.title.key == "History is paused (dictation)")
            guard case .plugin(let id, let perform) = banner.fix.first?.destination else {
                Issue.record("not a plugin action")
                return
            }
            #expect(id == "retry")
            await perform()
        }
        #expect(retried.count == 2)
        // The model comes first: without it nothing works.
        #expect(status(location: .missing, history: .failed)?.title.key == "1 thing to do")
    }

    // MARK: The plugin's banner

    /// Every file of `package` at its expected size, as sparse files: the model looks installed without a download
    /// and without using the disk space.
    private func installSparse(_ package: ModelPackage, in models: URL) throws {
        let folder = models.appending(path: "speech/\(package.id)", directoryHint: .isDirectory)
        for entry in package.files {
            let url = folder.appending(path: package.relativePath(of: entry.file, in: entry.source))
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(entry.file.size))
            try handle.close()
        }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test func readingTheBannerChangesNothingAndAsksForNothing() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let authorizer = FakeAuthorizer()
        authorizer.access.withLock { $0 = .notDetermined }
        let plugin = DictationPlugin(context: harness.context, makeBuiltInLLM: nil, authorizer: authorizer)
        plugin.appActivationCenter = NotificationCenter()
        try await plugin.activate()
        let changes = harness.changes.value
        let first = try #require(plugin.settingsStatus)
        let second = try #require(plugin.settingsStatus)
        #expect(first.title.key == "2 things to do")
        #expect(second.title.key == "2 things to do")
        #expect(authorizer.asked.withLock { $0 } == 0)
        #expect(harness.changes.value == changes)
        #expect(!FileManager.default.fileExists(atPath: harness.context.modelsDirectory.path))
        await plugin.deactivate()
    }

    @Test func allowingTheMicrophoneAndInstallingTheModelMakesItReady() async throws {
        let harness = try DictationHarness()
        defer { harness.tearDown() }
        let authorizer = FakeAuthorizer()
        authorizer.access.withLock { $0 = .notDetermined }
        let plugin = DictationPlugin(context: harness.context, makeBuiltInLLM: nil, authorizer: authorizer)
        let center = NotificationCenter()
        plugin.appActivationCenter = center
        try await plugin.activate()

        let allow = try #require(plugin.settingsStatus?.fix.first)
        guard case .plugin(let id, let perform) = allow.destination else {
            Issue.record("not a plugin action")
            return
        }
        #expect(id == "allowMicrophone")
        authorizer.access.withLock { $0 = .granted }
        let beforeAllow = harness.changes.value
        await perform()
        #expect(authorizer.asked.withLock { $0 } == 1)
        #expect(harness.changes.value > beforeAllow)
        let missing = try #require(plugin.settingsStatus)
        #expect(missing.title.key == "1 thing to do")
        #expect(missing.detail?.key == "The speech model isn’t installed.")

        // The model arrives elsewhere (the Models pane); coming back to Lintel reads it again.
        try installSparse(ModelCatalog.parakeetUltra, in: harness.context.modelsDirectory)
        #expect(plugin.settingsStatus?.title.key == "1 thing to do")
        let beforeActivation = harness.changes.value
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await eventually { plugin.settingsStatus?.title.key == "Ready" })
        #expect(harness.changes.value > beforeActivation)

        await plugin.deactivate()
        // Switched off: activations are no longer observed.
        try FileManager.default.removeItem(at: harness.context.modelsDirectory)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(plugin.settingsStatus?.title.key == "Ready")
    }

    @Test func theBannerStringsAreTranslated() throws {
        let url = Self.root.appending(path: "Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for key in [
            "1 thing to do", "2 things to do", "Get It in Models", "The speech model isn’t installed.",
            "The speech model’s folder isn’t available.", "Allow the microphone so Lintel can hear you.",
            "Allow the microphone and get the speech model.", "History is paused (dictation)",
            "Try Again (dictation history)", "Lintel can’t read the history’s key. Nothing was deleted.",
            "The history couldn’t be opened. Dictation still works.", "Speech model: %@.",
            "Press to start and again to stop, or hold.", "Clean up text",
            "Built-in model fixes punctuation and filler words.",
            "Your server on this Mac fixes punctuation and filler words.", "Keep a history",
            "Whisper listens for the language you choose.",
            "Lintel pastes through the clipboard and puts back what was there a second later.",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is missing from the catalog")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key)")
            #expect(localizations["en"] != nil, "\(key) has no en")
            #expect(localizations["pl"] != nil, "\(key) has no pl")
        }
    }
}
