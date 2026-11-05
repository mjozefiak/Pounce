import AppKit
import Foundation
import LintelKit
import LintelSpeech
import LintelUI
import SwiftUI
import Testing

@testable import MeetingsPlugin

/// Spec `2026-11-04-lintel-main-window`, step 5.2: the main window's Meetings pane on the `SettingsPane` template
/// (prototype `set-meetings`) and the plugin's own banner. No test here records, plays the system audio test or
/// shows a HUD.
@MainActor
@Suite struct MeetingsPaneTests {
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
            contentsOf: root.appending(path: "Sources/MeetingsPlugin/UI/MeetingsSettingsPane.swift"), encoding: .utf8)
    }

    /// The view types a `body` value holds (the branch an `if` took is stored, the other is not).
    private static func typeNames(in value: Any, depth: Int = 0) -> Set<String> {
        guard depth < 60 else { return [] }
        let type = String(describing: Swift.type(of: value))
        var names: Set<String> = [type.components(separatedBy: "<").first ?? type]
        for child in Mirror(reflecting: value).children {
            names.formUnion(typeNames(in: child.value, depth: depth + 1))
        }
        return names
    }

    // MARK: Structure

    @Test func theMainWindowPaneUsesTheTemplateAndNoModelCards() throws {
        let rig = try SettingsRig()
        let types = Self.typeNames(in: MeetingsPaneContent(model: rig.model, recorder: nil, isActive: false).body)
        #expect(types.contains("SettingsPane"))
        #expect(types.contains("ModelChoiceRow"))
        for legacy in [
            "MeetingsModelCard", "NotesSettingsRows", "MeetingsSuggestionsSection",
        ] {
            #expect(!types.contains(legacy), "\(legacy)")
        }
    }

    @Test func theRowsFollowThePrototypeOrder() throws {
        let source = try Self.paneSource()
        let rows = [
            "\"Basics\"", "\"Record meeting\"", "\"Write notes after each meeting\"", "\"Speech model\"",
            "\"Keep meetings for\"", "\"Input device\"", "\"Reduce echo from speakers\"",
            "\"Suggest recording when a meeting starts\"", "SystemAudioTestRow(", "\"Remind me to say I am recording\"",
            "\"Clear Library…\"", "\"Delete Temporary Recordings…\"",
        ]
        var position = source.range(of: "struct MeetingsPaneContent")?.upperBound ?? source.startIndex
        for row in rows {
            let found = try #require(source.range(of: row, range: position..<source.endIndex), "\(row) out of order")
            position = found.upperBound
        }
        #expect(source.contains("\"Privacy and data\", comment:"))
        // The notes model is a choice here; its download lives in Models (no "Download (≈ …)" card).
        #expect(source.contains("if model.notes.enabled {"))
        #expect(!source.contains("Download ("))
        #expect(!source.contains("Try it on an example"))
    }

    @Test func thePaneRendersAtEveryTextSize() throws {
        let rig = try SettingsRig()
        for size in [TextSize.small, .extraLarge] {
            let pane = MeetingsSettingsPane(model: rig.model, recorder: nil, isActive: false)
                .lintelTextSize(size)
                .frame(width: 680, height: 1200)
            #expect(ImageRenderer(content: pane).nsImage != nil)
        }
    }

    @Test func anInactiveMainWindowPaneReadsNothing() async throws {
        let rig = try SettingsRig()
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 800), styleMask: [.titled],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: MeetingsSettingsPane(model: rig.model, recorder: nil, isActive: false))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.model.devices.isEmpty)
        #expect(rig.authorizer.requests == 0)
    }

    @Test func theNotesModelSummaryFollowsItsState() throws {
        let rig = try SettingsRig()
        #expect(rig.model.notes.choiceState == .notInstalled)
    }

    // MARK: Banner

    private func status(
        location: ModelLocation = .installed(URL(filePath: "/tmp/model")),
        microphone: MicrophoneAccess = .granted,
        library: MeetingsLibrary.Status = .ready,
        denied: Int = 0,
        allow: @escaping @MainActor @Sendable () async -> Void = {},
        retry: @escaping @MainActor @Sendable () async -> Void = {}
    ) -> SettingsStatus? {
        MeetingsPlugin.settingsStatus(
            location: location, microphone: microphone, library: library, modelTitle: "Parakeet Ultra",
            packageID: ModelCatalog.parakeetUltra.id, deniedPermissions: denied, allowMicrophone: allow,
            retryLibrary: retry)
    }

    @Test func aFreshProfileHasTwoThingsToDoWithOneFixNextButton() async throws {
        let asked = Calls()
        let read = status(location: .missing, microphone: .notDetermined, allow: { asked.count += 1 })
        let banner = try #require(read)
        #expect(banner.level == .attention)
        #expect(banner.title.key == "2 things to do")
        #expect(banner.detail?.key == "Allow the microphone and get the speech model.")
        #expect(banner.fix.map(\.title.key) == ["Fix Next"])
        guard case .plugin(let id, let perform) = banner.fix.first?.destination else {
            Issue.record("not a plugin action")
            return
        }
        #expect(id == "allowMicrophone")
        #expect(asked.count == 0)
        await perform()
        #expect(asked.count == 1)
    }

    @Test func aMissingModelAloneOffersGetItInModels() throws {
        for location in [ModelLocation.missing, .partial(bytes: 10)] {
            let banner = try #require(status(location: location))
            #expect(banner.level == .attention)
            #expect(banner.title.key == "1 thing to do")
            #expect(banner.detail?.key == "The speech model isn’t installed.")
            #expect(banner.fix.map(\.title.key) == ["Get It in Models"])
            guard case .models(let packageID) = banner.fix.first?.destination else {
                Issue.record("not a Models action")
                return
            }
            #expect(packageID == ModelCatalog.parakeetUltra.id)
        }
        let gone = try #require(status(location: .customFolderUnavailable(URL(filePath: "/Volumes/Gone"))))
        #expect(gone.detail?.key == "The speech model’s folder isn’t available.")
    }

    @Test func aDeniedMicrophoneIsCountedWithTheMissingModel() throws {
        // The shell adds "Microphone: not allowed" to the detail, so the title counts it.
        let banner = try #require(status(location: .missing, microphone: .denied, denied: 1))
        #expect(banner.title.key == "2 things to do")
        #expect(banner.detail?.key == "The speech model isn’t installed.")
        #expect(status(microphone: .denied, denied: 1)?.title.key == "Ready")
    }

    @Test func anUnaskedMicrophoneAloneOffersAllowMicrophone() throws {
        let banner = try #require(status(microphone: .notDetermined))
        #expect(banner.title.key == "1 thing to do")
        #expect(banner.detail?.key == "Allow the microphone so Lintel can hear the meeting.")
        #expect(banner.fix.map(\.title.key) == ["Allow Microphone"])
    }

    @Test func aModelAndAnAnsweredMicrophoneAreReady() throws {
        for microphone in [MicrophoneAccess.granted, .denied] {
            for location in [ModelLocation.installed(URL(filePath: "/a")), .customFolder(URL(filePath: "/b"))] {
                // A denied microphone is the shell's derivation ("Microphone: not allowed"), not the plugin's.
                let banner = try #require(status(location: location, microphone: microphone))
                #expect(banner.level == .ok)
                #expect(banner.title.key == "Ready")
                #expect(banner.fix.isEmpty)
                #expect(banner.acknowledgedPermissions.isEmpty)
            }
        }
    }

    @Test func aLockedLibraryIsAnErrorWithTryAgainAndComesFirst() async throws {
        let retried = Calls()
        for library in [MeetingsLibrary.Status.unavailable(.denied), .failed] {
            let read = status(
                location: .missing, microphone: .notDetermined, library: library, retry: { retried.count += 1 })
            let banner = try #require(read)
            #expect(banner.level == .error)
            #expect(banner.title.key == "Meetings are paused")
            #expect(banner.fix.map(\.title.key) == ["Try Again (meetings library)"])
            guard case .plugin(let id, let perform) = banner.fix.first?.destination else {
                Issue.record("not a plugin action")
                return
            }
            #expect(id == "retry")
            await perform()
        }
        #expect(retried.count == 2)
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

    @Test func aFreshProfileReadsTwoThingsToDoAndFixNextAsksOnlyOnTheClick() async throws {
        let harness = try MeetingsHarness()
        let authorizer = FakeAuthorizer(.notDetermined)
        let plugin = MeetingsPlugin(context: harness.context, authorizer: authorizer)
        let center = NotificationCenter()
        plugin.appActivationCenter = center
        try await plugin.activate()

        // Reading changes nothing and asks for nothing.
        let changes = harness.changes.get()
        let first = try #require(plugin.settingsStatus)
        let second = try #require(plugin.settingsStatus)
        #expect(first.title.key == "2 things to do")
        #expect(second.title.key == "2 things to do")
        #expect(authorizer.requests == 0)
        #expect(harness.changes.get() == changes)

        // "Fix Next" asks for the microphone; the next fix is the speech model in Models.
        guard case .plugin(let id, let perform) = first.fix.first?.destination else {
            Issue.record("not a plugin action")
            return
        }
        #expect(id == "allowMicrophone")
        await perform()
        #expect(authorizer.requests == 1)
        #expect(harness.changes.get() > changes)
        let next = try #require(plugin.settingsStatus)
        #expect(next.title.key == "1 thing to do")
        #expect(next.detail?.key == "The speech model isn’t installed.")
        guard case .models(let packageID) = next.fix.first?.destination else {
            Issue.record("not a Models action")
            return
        }
        #expect(packageID == ModelCatalog.parakeetUltra.id)

        // The speech model arrives in Models; the speaker model is still missing and is not counted.
        try installSparse(ModelCatalog.parakeetUltra, in: harness.context.modelsDirectory)
        let beforeActivation = harness.changes.get()
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(await eventually { plugin.settingsStatus?.title.key == "Ready" })
        #expect(harness.changes.get() > beforeActivation)
        #expect(plugin.ui.model.diarization.isInstalled == false)

        await plugin.deactivate()
    }

    @Test func theBannerAndPaneStringsAreTranslated() throws {
        let url = Self.root.appending(path: "Resources/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(catalog?["strings"] as? [String: Any])
        for key in [
            "2 things to do", "1 thing to do", "Fix Next", "Allow the microphone and get the speech model.",
            "Allow the microphone so Lintel can hear the meeting.", "Meetings are paused",
            "Lintel can’t read the library’s key. Nothing was deleted.",
            "The library couldn’t be opened. Nothing was deleted.", "Try Again (meetings library)",
            "Privacy and data", "Library", "Notes model", "Reduce echo from speakers", "Can lower other apps’ volume.",
            "Press to start and again to stop.", "Summary, decisions, tasks. Needs the notes model.",
            "Remind me to say I am recording", "Temporary recordings", "Audio of interrupted meetings.",
            "Test (system audio)",
        ] {
            let entry = try #require(strings[key] as? [String: Any], "\(key) is missing from the catalog")
            let localizations = try #require(entry["localizations"] as? [String: Any], "\(key)")
            #expect(localizations["en"] != nil, "\(key) has no en")
            #expect(localizations["pl"] != nil, "\(key) has no pl")
        }
    }
}
