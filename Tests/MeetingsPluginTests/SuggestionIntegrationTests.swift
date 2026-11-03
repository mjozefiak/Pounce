import Foundation
import GRDB
import PounceKit
import PounceSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct SuggestionIntegrationTests {
    // MARK: Prompt

    @Test func theMeetingPromptNamesTheAppAndOffersThreeButtons() {
        let prompt = SuggestionPrompt.meeting(bundleID: "us.zoom.xos", appName: "Zoom")
        #expect(prompt.title == "Looks like a meeting in Zoom")
        #expect(prompt.actions == [.record, .notNow, .muteApp])
        #expect(prompt.title(for: .record) == "Record")
        #expect(prompt.title(for: .notNow) == "Not now")
        #expect(prompt.title(for: .muteApp) == "Don't ask for this app")
        #expect(prompt.accessibilityLabel == prompt.title)
        #expect(prompt.announcement == prompt.title)
    }

    @Test func theEndPromptOffersEndAndKeep() {
        let prompt = SuggestionPrompt.endRecording(appName: "Zoom")
        #expect(prompt.title == "End the recording?")
        #expect(prompt.actions == [.endRecording, .keepRecording])
        #expect(prompt.title(for: .endRecording) == "End recording")
        #expect(prompt.title(for: .keepRecording) == "Keep recording")
    }

    // MARK: Source bundle ID

    @Test func theControllerPassesTheAppOnlyWhenStartedFromTheSuggestion() async throws {
        let rig = try ControllerRig()
        rig.controller.start()
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == nil)
        rig.controller.stop()
        await eventually("idle") { rig.controller.phase == .idle }

        rig.controller.start(fromSuggestionOf: "us.zoom.xos")
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == "us.zoom.xos")
        rig.controller.stop()
        await eventually("idle") { rig.controller.phase == .idle }

        // The next one started by the shortcut does not inherit it.
        rig.controller.toggle()
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == nil)
    }

    @Test func aSuggestionStartIgnoredWhileRecordingStoresNothing() async throws {
        let rig = try ControllerRig()
        await rig.startRecording()
        rig.controller.start(fromSuggestionOf: "us.zoom.xos")
        #expect(rig.requests.count == 1)
        rig.controller.stop()
        await eventually("idle") { rig.controller.phase == .idle }
        rig.controller.start()
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == nil)
    }

    @Test func aRefusedStartDoesNotLeakTheAppIntoTheNextRecording() async throws {
        let rig = try ControllerRig(access: .denied)
        rig.controller.start(fromSuggestionOf: "us.zoom.xos")
        await eventually("denied") { rig.hud.last == .problem(.microphoneDenied(offersSystemOnly: true)) }
        rig.controller.perform(.dismiss)
        rig.controller.start()
        await eventually("denied again") { rig.controller.phase == .awaitingMicrophoneDecision }
        rig.controller.perform(.recordSystemAudioOnly)
        await eventually("recording") { rig.controller.phase == .recording }
        #expect(rig.requests.last?.sourceBundleID == nil)
    }

    @Test func theSessionWritesSourceBundleIDOnlyWhenGiven() async throws {
        let rig = try SessionRig()
        let silent = TrackScript()
        let withApp = rig.session(mic: silent, system: nil, sourceBundleID: "us.zoom.xos")
        let first = try await withApp.start()
        #expect(try sourceBundleID(rig, first) == "us.zoom.xos")
        rig.mic.end()
        _ = await withApp.finish()

        let without = rig.session(mic: silent, system: nil)
        let second = try await without.start()
        #expect(try sourceBundleID(rig, second) == nil)
        rig.mic.end()
        _ = await without.finish()
    }

    private func sourceBundleID(_ rig: SessionRig, _ id: Int64) throws -> String? {
        try rig.store.read { db in
            try String?.fetchOne(db, sql: "SELECT source_bundle_id FROM meeting WHERE id = ?", arguments: [id]) ?? nil
        }
    }

    // MARK: Settings model

    private func model(_ settings: [String: SettingValue] = [:]) throws -> (MeetingsSettingsModel, MeetingsHarness) {
        let harness = try MeetingsHarness(settings: settings)
        let plugin = MeetingsPlugin(context: harness.context)
        return (plugin.ui.model, harness)
    }

    @Test func suggestionsAreOffByDefaultAndTheSwitchPersists() throws {
        let (model, harness) = try model()
        #expect(model.suggestMeetings == false)
        #expect(harness.meetingsSettings.suggestMeetings == false)
        var calls = 0
        model.suggestionsChanged = { calls += 1 }
        model.suggestMeetings = true
        #expect(harness.meetingsSettings.suggestMeetings)
        #expect(calls == 1)
        model.suggestMeetings = true
        #expect(calls == 1)
        model.suggestMeetings = false
        #expect(!harness.meetingsSettings.suggestMeetings)
        #expect(calls == 2)
    }

    @Test func theMutedListPersistsAndCanBeEmptied() throws {
        let (model, harness) = try model([
            "plugins.meetings.suggestMutedBundleIDs": .stringArray(["us.zoom.xos", "com.hnc.Discord"])
        ])
        #expect(model.mutedApps.map(\.id) == ["us.zoom.xos", "com.hnc.Discord"])
        #expect(model.mutedApps.first?.name == "Zoom")
        model.unmute("us.zoom.xos")
        #expect(harness.meetingsSettings.suggestMutedBundleIDs == ["com.hnc.Discord"])
        #expect(model.mutedApps.map(\.id) == ["com.hnc.Discord"])
    }

    @Test func extraAppsAreValidatedAndPersisted() throws {
        let (model, harness) = try model()
        #expect(model.addExtraApp("  com.google.Chrome  "))
        #expect(harness.meetingsSettings.suggestExtraBundleIDs == ["com.google.Chrome"])
        #expect(!model.addExtraApp("com.google.Chrome"))
        #expect(model.extraAppError == .duplicate)
        let invalid = [
            "", "Chrome", "com.google.", ".com", "com google", "com.göogle", String(repeating: "a.", count: 200),
        ]
        for bad in invalid {
            #expect(!model.addExtraApp(bad), "\(bad)")
            #expect(model.extraAppError == .invalid)
        }
        for index in 0..<(MeetingsSettingsModel.maximumExtraApps - 1) {
            #expect(model.addExtraApp("com.example.app\(index)"))
        }
        #expect(!model.addExtraApp("com.example.onetoomany"))
        #expect(model.extraAppError == .tooMany)
        model.removeExtraApp("com.google.Chrome")
        #expect(!harness.meetingsSettings.suggestExtraBundleIDs.contains("com.google.Chrome"))
    }

    // MARK: Plugin lifecycle

    /// A plugin whose detector sees a scripted observer, a manual clock and a recording HUD, and whose
    /// controller records with scripted sessions. Nothing reaches Core Audio.
    private struct PluginRig {
        let harness: MeetingsHarness
        let plugin: MeetingsPlugin
        let observer = ScriptedProcessObserver()
        let presenter = RecordingSuggestionPresenter()
        let detectorClock = ManualClock()
        let controllerClock = ManualClock()
        let sessions = Shared([ScriptedSession]())
        let requests = Shared([MeetingSessionRequest]())

        @MainActor
        init(settings: [String: SettingValue] = [:], context: ((MeetingsHarness) -> PluginContext)? = nil) throws {
            harness = try MeetingsHarness(settings: settings)
            plugin = MeetingsPlugin(context: context?(harness) ?? harness.context)
            let observer = observer
            let presenter = presenter
            let detectorClock = detectorClock
            let controllerClock = controllerClock
            let sessions = sessions
            let requests = requests
            plugin.adjustDetectorDependencies = { dependencies in
                dependencies.observer = observer
                dependencies.presenter = presenter
                dependencies.clock = DetectorClock(detectorClock)
                dependencies.didProcess = { ChangeSignal.shared.fire() }
            }
            plugin.adjustControllerDependencies = { dependencies in
                dependencies.authorizer = FakeAuthorizer(.granted)
                dependencies.speechModel = {
                    .ready(modelID: "parakeet-ultra", folder: URL(filePath: "/tmp/pounce-model"))
                }
                dependencies.makeSession = { request in
                    let session = ScriptedSession()
                    sessions.update { $0.append(session) }
                    requests.update { $0.append(request) }
                    return session
                }
                dependencies.clock = controllerClock
                dependencies.shutdownTimeout = .seconds(5)
                dependencies.stateChanged = { ChangeSignal.shared.fire() }
            }
        }
    }

    @Test func theDetectorDoesNotListenWhileTheSettingIsOff() async throws {
        let rig = try PluginRig()
        try await rig.plugin.activate()
        #expect(rig.plugin.detector?.status == .off)
        #expect(rig.observer.startCount == 0)
        await rig.plugin.deactivate()
        #expect(rig.observer.startCount == 0)
    }

    @Test func theSwitchStartsAndStopsTheListening() async throws {
        let rig = try PluginRig()
        try await rig.plugin.activate()
        let model = rig.plugin.ui.model
        model.suggestMeetings = true
        #expect(rig.observer.isListening)
        #expect(model.suggestionStatus == .listening)
        model.suggestMeetings = false
        #expect(!rig.observer.isListening)
        #expect(rig.observer.stopCount == 1)
        #expect(model.suggestionStatus == .off)
        await rig.plugin.deactivate()
    }

    @Test func deactivatingThePluginStopsTheListeningAndRemovesTheDetector() async throws {
        let rig = try PluginRig(settings: ["plugins.meetings.suggestMeetings": .bool(true)])
        try await rig.plugin.activate()
        #expect(rig.observer.isListening)
        await rig.plugin.deactivate()
        #expect(!rig.observer.isListening)
        #expect(rig.plugin.detector == nil)
        #expect(rig.observer.stopCount == 1)
        // Reactivating listens again.
        try await rig.plugin.activate()
        #expect(rig.observer.startCount == 2)
        await rig.plugin.deactivate()
    }

    @Test func anUnavailableAPIShowsInSettingsAndChangesNothingElse() async throws {
        let harness = try MeetingsHarness(settings: ["plugins.meetings.suggestMeetings": .bool(true)])
        let plugin = MeetingsPlugin(context: harness.context)
        plugin.adjustDetectorDependencies = {
            $0.observer = ScriptedProcessObserver(failure: .unavailable(-1))
            $0.presenter = RecordingSuggestionPresenter()
        }
        try await plugin.activate()
        #expect(plugin.ui.model.suggestionStatus == .unavailable)
        #expect(plugin.controller != nil)
        #expect(plugin.library.status == .ready)
        await plugin.deactivate()
    }

    // MARK: The whole flow

    @Test func aSuggestionOnlyStartsARecordingWhenTheUserClicksRecordAndAsksBeforeEnding() async throws {
        let rig = try PluginRig(settings: ["plugins.meetings.suggestMeetings": .bool(true)])
        try await rig.plugin.activate()
        let detector = try #require(rig.plugin.detector)
        let controller = try #require(rig.plugin.controller)

        rig.observer.input(1, "us.zoom.xos")
        await eventually("event handled") { detector.processedCount >= 1 }
        await eventually("timer waits") { rig.detectorClock.sleepers >= 1 }
        rig.detectorClock.advance(by: .seconds(10))
        await eventually("suggested") { rig.presenter.last == .meeting(bundleID: "us.zoom.xos", appName: "Zoom") }
        // Nothing started by itself.
        #expect(rig.requests.get().isEmpty)
        #expect(controller.phase == .idle)

        detector.perform(.record)
        await eventually("recording") { controller.phase == .recording }
        #expect(rig.requests.get().last?.sourceBundleID == "us.zoom.xos")

        // Sound on a track postpones the question; the app leaves the call; silence for a minute asks.
        let session = try #require(rig.sessions.get().last)
        session.send(.level(.system, 0.5))
        rig.observer.input(1, nil, running: false)
        await eventually("event handled") { detector.processedCount >= 2 }
        await eventually("timer waits") { rig.detectorClock.sleepers >= 1 }
        rig.detectorClock.advance(by: .seconds(60))
        await eventually("asked") { rig.presenter.last == .endRecording(appName: "Zoom") }
        #expect(session.finishCount == 0)

        detector.perform(.endRecording)
        await eventually("finishing") { session.finishCount == 1 }
        await eventually("idle") { controller.phase == .idle }
        await rig.plugin.deactivate()
    }

    @Test func theSuggestionFlowClaimsNoGlobalKeys() async throws {
        let claims = Shared(0)
        let rig = try PluginRig(
            settings: ["plugins.meetings.suggestMeetings": .bool(true)],
            context: { harness in
                let base = harness.context
                return PluginContext(
                    storageDirectory: base.storageDirectory, settings: base.settings, usage: base.usage,
                    logger: base.logger, keychain: base.keychain, pasteboard: base.pasteboard, events: base.events,
                    workspace: base.workspace, permissions: base.permissions, clock: base.clock,
                    claimEscapeKey: { _ in
                        claims.update { $0 += 1 }
                        return .inactive
                    }, modelsDirectory: base.modelsDirectory)
            })
        try await rig.plugin.activate()
        let detector = try #require(rig.plugin.detector)
        rig.observer.input(1, "us.zoom.xos")
        await eventually("timer waits") { rig.detectorClock.sleepers >= 1 }
        rig.detectorClock.advance(by: .seconds(10))
        await eventually("suggested") { rig.presenter.last != nil }
        detector.perform(.notNow)
        #expect(claims.get() == 0)
        await rig.plugin.deactivate()
        #expect(claims.get() == 0)
    }

    private func sourceFiles() throws -> [(name: String, text: String)] {
        let directory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/MeetingsPlugin", directoryHint: .isDirectory)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path()).filter {
            $0.hasSuffix(".swift")
        }
        #expect(names.count > 30)
        return try names.sorted().map {
            ($0, try String(contentsOf: directory.appending(path: $0), encoding: .utf8))
        }
    }

    /// The source without comments (a comment may say "no keyDown"), so only code is judged.
    private func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func noFileOfThePluginTakesKeysOrRegistersShortcuts() throws {
        // The whole plugin, not a list of files: no part of the meetings feature claims a key.
        let forbidden = [
            "claimEscapeKey", "addGlobalMonitorForEvents", "addLocalMonitorForEvents", "RegisterEventHotKey",
            "keyboardShortcut", "KeyboardShortcuts", "CGEventTap", "performKeyEquivalent", "keyDown", "keyUp",
            "NSEvent.addMonitor", "onKeyPress", "onKeyEvent", "defaultAction", "cancelAction", "keyEquivalent",
            "CGEvent.tapCreate", "makeShortcutRecorder",
        ]
        for (name, text) in try sourceFiles() where name != "MeetingsPlugin+Settings.swift" {
            let source = code(text)
            for word in forbidden {
                #expect(!source.contains(word), "\(name) mentions \(word)")
            }
        }
    }

    @Test func theHUDIsHiddenFromScreenSharingAndDoesNotActivate() throws {
        let source = try #require(try sourceFiles().first { $0.name == "SuggestionHUD.swift" }).text
        #expect(source.contains("panel.sharingType = .none"))
        #expect(source.contains(".nonactivatingPanel"))
        #expect(source.contains("announcementRequested"))
        #expect(source.contains("accessibilityReduceMotion"))
    }

    @Test func detectionNeverTouchesAudioAndLogsNothingAboutAppsOrProcesses() throws {
        let files = try sourceFiles()
        let observer = code(try #require(files.first { $0.name == "CoreAudioProcessObserver.swift" }).text)
        for word in [
            "AudioHardwareCreateProcessTap", "AudioDeviceStart", "AVAudioEngine", "AudioDeviceCreateIOProc",
            "AudioUnit", "AVCaptureDevice", "kAudioProcessPropertyBundleID" + "Name",
        ] {
            #expect(!observer.contains(word), "\(word)")
        }
        // Every logger call in the detection files, however it is wrapped over lines, uses a literal without
        // an interpolation.
        for name in [
            "MeetingDetector.swift", "SuggestionPolicy.swift", "CoreAudioProcessObserver.swift",
            "ProcessAudioObserver.swift", "MeetingsPlugin+Suggestions.swift", "SuggestionHUD.swift",
            "SuggestionPrompt.swift", "MeetingsSettingsModel+Suggestions.swift",
        ] {
            let text = code(try #require(files.first { $0.name == name }).text)
            for call in loggerCalls(in: text) {
                #expect(!call.contains("\\("), "\(name): \(call)")
            }
        }
        let detector = code(try #require(files.first { $0.name == "MeetingDetector.swift" }).text)
        #expect(loggerCalls(in: detector).count >= 2)
    }

    /// The text of every `logger.<level>(...)` call, parentheses balanced across lines.
    private func loggerCalls(in text: String) -> [String] {
        var calls: [String] = []
        var rest = Substring(text)
        while let range = rest.range(of: "logger.") {
            let after = rest[range.upperBound...]
            guard let open = after.firstIndex(of: "(") else { break }
            var depth = 0
            var end = open
            for index in after[open...].indices {
                if after[index] == "(" { depth += 1 }
                if after[index] == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = index
                        break
                    }
                }
            }
            calls.append(String(after[open...end]))
            rest = after[end...]
        }
        return calls
    }
}
