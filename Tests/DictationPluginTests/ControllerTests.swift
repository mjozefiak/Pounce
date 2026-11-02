import Foundation
import PounceKit
import Synchronization
import Testing
import os

@testable import DictationPlugin

@MainActor final class FakeHUD: HUDPresenter {
    private(set) var states: [HUDState] = []
    private(set) var hidden = 0
    func show(_ state: HUDState) { states.append(state) }
    func hide() { hidden += 1 }

    var last: HUDState? { states.last }
    /// The states without the level updates of a recording.
    var milestones: [String] {
        states.compactMap { state in
            switch state {
            case .recording: "recording"
            case .finishing: "finishing"
            case .pasted: "pasted"
            case .pastedUnformatted(let all): "pastedUnformatted:\(all)"
            case .copied: "copied"
            case .problem(let problem): "problem:\(problem)"
            case .allowMicrophone: "allow"
            }
        }.reduce(into: []) { if $0.last != $1 { $0.append($1) } }
    }
}

final class FakeAuthorizer: MicrophoneAuthorizer, @unchecked Sendable {
    let access = Mutex<MicrophoneAccess>(.granted)
    let grantsWhenAsked = Mutex(true)
    let asked = Mutex(0)

    func status() -> MicrophoneAccess { access.withLock { $0 } }

    func requestAccess() async -> Bool {
        asked.withLock { $0 += 1 }
        return grantsWhenAsked.withLock { $0 }
    }
}

@MainActor
@Suite struct DictationControllerTests {
    @MainActor final class Rig {
        let hud = FakeHUD()
        let authorizer = FakeAuthorizer()
        let engine = FakeEngine()
        let directory: TemporaryDirectory
        let paste = TextPasterTests.Rig()
        let models: ModelManager
        let package: ModelPackage
        var escapeHandler: (@MainActor @Sendable () -> Void)?
        var escapeReleases = 0
        var escapeAvailable = true
        var settingsOpened = 0
        var audioSeconds = 5.0
        var ranges = [(1 * AudioFormat.sampleRate)..<(2 * AudioFormat.sampleRate)]
        var audioStarted = 0
        var formatter: (any TextFormatter)?
        var recorded: [DictationEntry] = []
        var mode = FormatMode.raw
        var now = ContinuousClock.now
        var installed = true

        init() throws {
            directory = try TemporaryDirectory()
            let data = Data("model".utf8)
            package = ModelPackage(
                id: "fixture", title: "Fixture", license: "MIT", attribution: "",
                sources: [
                    ModelSource(
                        repository: "test/x", revision: "r", into: "",
                        files: [ModelFile(path: "weights.bin", size: data.count, sha256: "unused")])
                ])
            models = ModelManager(directory: directory.url.appending(path: "Models"))
            let folder = directory.url.appending(path: "Models/fixture", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appending(path: "weights.bin"))
        }

        func removeModel() throws {
            try FileManager.default.removeItem(at: directory.url.appending(path: "Models/fixture"))
        }

        func controller(keepWarm: Duration = .seconds(600)) -> DictationController {
            let hud = hud
            let engine = engine
            let rig = self
            return DictationController(
                .init(
                    authorizer: authorizer, models: models, package: { [package] in package },
                    customFolder: { nil },
                    makeSession: { folder, onEvent in
                        rig.audioStarted += 1
                        return DictationSession(
                            audio: ScriptedAudioInput(seconds: rig.audioSeconds), vad: RangeVAD(rig.ranges),
                            engine: engine, formatter: rig.formatter, modelFolder: folder,
                            onEvent: onEvent)
                    },
                    engine: engine, paster: paste.paster(), hud: hud,
                    claimEscape: { handler in
                        rig.escapeHandler = handler
                        guard rig.escapeAvailable else { return .inactive }
                        return EscapeKeyClaim(isActive: true) { rig.escapeReleases += 1 }
                    },
                    openSettings: { rig.settingsOpened += 1 },
                    keepWarm: { keepWarm }, clock: paste.clock, now: { rig.now },
                    recordHistory: { rig.recorded.append($0) },
                    frontmostBundleID: { "com.example.target" },
                    formatMode: { rig.mode }, speechModelID: { "fixture" }, formatterModel: { "qwen" }))
        }

        func tearDown() { paste.pasteboard.release() }
    }

    /// Waits until the HUD shows a final state.
    private func settle(_ rig: Rig) async {
        for _ in 0..<200 {
            if let last = rig.hud.last, last.hidesAfter != nil { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func tapToStartTapToStopPastesTheText() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.keyEvent(.down)
        rig.now += .milliseconds(100)
        controller.keyEvent(.up)
        try await Task.sleep(for: .milliseconds(100))
        controller.keyEvent(.down)
        controller.keyEvent(.up)
        await settle(rig)

        #expect(rig.hud.milestones == ["recording", "finishing", "pasted"])
        #expect(rig.paste.pasteboard.string() == "segment 1")
        #expect(rig.paste.events.posts == 1)
        #expect(rig.escapeReleases == 1)
        #expect(controller.lastRawText == "segment 1")
        #expect(!controller.isBusy)
    }

    @Test func holdToTalkPastesAtKeyUp() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.keyEvent(.down)
        try await Task.sleep(for: .milliseconds(100))
        rig.now += .milliseconds(900)
        controller.keyEvent(.up)
        await settle(rig)
        #expect(rig.hud.milestones == ["recording", "finishing", "pasted"])
        #expect(rig.paste.pasteboard.string() == "segment 1")
    }

    @Test func escapeCancelsAndNothingIsPasted() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.keyEvent(.down)
        try await Task.sleep(for: .milliseconds(100))
        let escape = try #require(rig.escapeHandler)
        escape()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.hud.hidden == 1)
        #expect(rig.paste.events.posts == 0)
        #expect(rig.paste.pasteboard.string() == nil)
        #expect(rig.escapeReleases == 1)
        #expect(!controller.isBusy)
        // The key-up of the cancelled press does nothing.
        controller.keyEvent(.up)
        #expect(!controller.isBusy)
    }

    @Test func theHUDSaysWhenEscapeCouldNotBeClaimed() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.escapeAvailable = false
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        guard case .recording(let recording)? = rig.hud.states.first(where: { $0.offersCancel }) else {
            Issue.record("no recording state")
            return
        }
        #expect(!recording.escapeCancels)
        #expect(HUDState.recording(recording).detail == "✕ cancels")
        controller.cancel()
    }

    @Test func theMenuStartsAToggleRecordingAndEndsIt() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)
        #expect(rig.hud.milestones == ["recording", "finishing", "pasted"])
    }

    @Test func withoutAModelNothingIsRecorded() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        try rig.removeModel()
        let controller = rig.controller()
        controller.keyEvent(.down)
        await settle(rig)
        #expect(rig.hud.milestones == ["problem:modelMissing"])
        #expect(rig.audioStarted == 0)
        #expect(!controller.isBusy)
        #expect(HUDState.problem(.modelMissing).offersSettings)
    }

    @Test func aDeniedMicrophoneShowsAMessageAndNeverRecords() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.authorizer.access.withLock { $0 = .denied }
        let controller = rig.controller()
        controller.keyEvent(.down)
        await settle(rig)
        #expect(rig.hud.milestones == ["problem:microphoneDenied"])
        #expect(rig.audioStarted == 0)
        #expect(rig.authorizer.asked.withLock { $0 } == 0)
    }

    @Test func theMicrophoneIsAskedForOnTheKeyPressOnly() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.authorizer.access.withLock { $0 = .notDetermined }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(150))
        #expect(rig.authorizer.asked.withLock { $0 } == 1)
        #expect(rig.hud.milestones.first == "allow")
        #expect(rig.hud.milestones.contains("recording"))
        controller.cancel()

        let refused = try Rig()
        defer { refused.tearDown() }
        refused.authorizer.access.withLock { $0 = .notDetermined }
        refused.authorizer.grantsWhenAsked.withLock { $0 = false }
        let second = refused.controller()
        second.keyEvent(.down)
        await settle(refused)
        #expect(refused.hud.milestones == ["allow", "problem:microphoneDenied"])
        #expect(refused.audioStarted == 0)
    }

    @Test func aRecordingWithoutSpeechSaysNothingWasHeard() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.ranges = []
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)
        #expect(rig.hud.milestones == ["recording", "finishing", "problem:nothingHeard"])
        #expect(rig.paste.events.posts == 0)
        #expect(controller.lastRawText == nil)
    }

    @Test func aSecondPressWhileFinishingIsIgnored() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.engine.delays = [1: .milliseconds(200)]
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        try await Task.sleep(for: .milliseconds(30))
        controller.keyEvent(.down)
        controller.keyEvent(.up)
        controller.menu()
        await settle(rig)
        #expect(rig.hud.milestones == ["recording", "finishing", "pasted"])
        #expect(rig.audioStarted == 1)
        #expect(rig.paste.events.posts == 1)
    }

    @Test func theModelIsUnloadedAfterTheKeepWarmTime() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller(keepWarm: .seconds(600))
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)
        // The test clock returns at once, so the keep-warm timer has already fired.
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.engine.state.withLock { $0.unloads } >= 1)
        #expect(rig.paste.clock.sleeps.contains(.seconds(600)))
    }

    @Test func shuttingDownDropsTheRecording() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        await controller.shutDown()
        #expect(rig.escapeReleases == 1)
        #expect(rig.paste.events.posts == 0)
        #expect(rig.engine.state.withLock { $0.unloads } == 1)
    }

    // MARK: Formatting

    @Test func formattedTextIsPastedAndTheRawTextIsKept() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.formatter = StubFormatter { chunk, _ in FormatResult(text: "Clean: \(chunk)", outcome: .formatted) }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)

        #expect(rig.paste.pasteboard.string() == "Clean: segment 1")
        #expect(controller.lastRawText == "segment 1")
        #expect(rig.hud.milestones == ["recording", "finishing", "pasted"])
    }

    @Test func aFallbackIsAnnouncedAndTheRawTextIsPasted() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.formatter = StubFormatter { chunk, _ in FormatResult(text: chunk, outcome: .fellBack(.unreachable)) }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)

        #expect(rig.paste.pasteboard.string() == "segment 1")
        #expect(rig.hud.last == .pastedUnformatted(all: true))
    }

    @Test func pasteLastRawPastesTheTranscriptWithoutFormatting() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.formatter = StubFormatter { _, _ in FormatResult(text: "Formatted", outcome: .formatted) }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)
        #expect(rig.paste.pasteboard.string() == "Formatted")

        controller.pasteLastRaw()
        for _ in 0..<200 where rig.paste.events.posts < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.paste.pasteboard.string() == "segment 1")
        #expect(rig.paste.events.posts == 2)
    }

    @Test func pasteLastRawWithNothingDictatedSaysSo() throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.pasteLastRaw()
        #expect(rig.hud.last == .problem(.nothingToPaste))
        #expect(rig.paste.events.posts == 0)
    }

    // MARK: History

    private func dictate(_ rig: Rig, _ controller: DictationController) async throws {
        controller.menu()
        try await Task.sleep(for: .milliseconds(100))
        controller.menu()
        await settle(rig)
    }

    @Test func aRawDictationIsRecordedAfterThePaste() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        try await dictate(rig, controller)

        let entry = try #require(rig.recorded.first)
        #expect(rig.recorded.count == 1)
        #expect(entry.rawText == "segment 1")
        #expect(entry.formattedText == nil)
        #expect(entry.formatMode == .raw)
        #expect(entry.formatStatus == .none)
        #expect(entry.pasteResult == .pasted)
        #expect(entry.targetBundleID == "com.example.target")
        #expect(entry.speechModelID == "fixture")
        #expect(entry.formatterModel == nil)
    }

    @Test func aCleanedDictationKeepsBothVersions() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.mode = .clean
        rig.formatter = StubFormatter { chunk, _ in FormatResult(text: "Clean \(chunk)", outcome: .formatted) }
        let controller = rig.controller()
        try await dictate(rig, controller)

        let entry = try #require(rig.recorded.first)
        #expect(entry.rawText == "segment 1")
        #expect(entry.formattedText == "Clean segment 1")
        #expect(entry.formatMode == .clean)
        #expect(entry.formatStatus == .ok)
        #expect(entry.formatterModel == "qwen")
    }

    @Test func aFailedFormattingIsRecordedAsFailedWithoutAFormattedText() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.mode = .clean
        rig.formatter = StubFormatter { chunk, _ in FormatResult(text: chunk, outcome: .fellBack(.unreachable)) }
        let controller = rig.controller()
        try await dictate(rig, controller)

        let entry = try #require(rig.recorded.first)
        #expect(entry.formatStatus == .failed)
        #expect(entry.formattedText == nil)
        #expect(entry.bestText == "segment 1")
    }

    @Test func aCopyOnlyResultIsRecordedWithoutATarget() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        rig.paste.permissions.states[.accessibility] = .denied
        let controller = rig.controller()
        try await dictate(rig, controller)

        let entry = try #require(rig.recorded.first)
        #expect(entry.pasteResult == .copied)
        #expect(entry.targetBundleID == nil)
    }

    @Test func aCancelledOrSilentRecordingLeavesNoEntry() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        controller.menu()
        try await Task.sleep(for: .milliseconds(50))
        controller.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.recorded.isEmpty)
    }

    @Test func pastingFromTheHistoryDoesNotRecordAgain() async throws {
        let rig = try Rig()
        defer { rig.tearDown() }
        let controller = rig.controller()
        await controller.pasteFromHistory("from the history")
        #expect(rig.paste.pasteboard.string() == "from the history")
        #expect(rig.recorded.isEmpty)
    }
}

@Suite struct HUDStateTests {
    @Test func everyStateHasATitleASymbolAndTheRightButtons() {
        let states: [HUDState] = [
            .allowMicrophone, .recording(.init()), .recording(.init(loadingModel: true)), .finishing, .pasted,
            .copied(.noAccessibility), .copied(.secureEventInput), .problem(.modelMissing),
            .problem(.modelUnavailable), .problem(.modelFailedToLoad), .problem(.microphoneDenied),
            .problem(.noMicrophone), .problem(.nothingHeard), .problem(.nothingToPaste),
            .pastedUnformatted(all: true), .pastedUnformatted(all: false),
        ]
        for state in states {
            #expect(!state.title.isEmpty)
            #expect(!state.symbolName.isEmpty)
            #expect(!state.accessibilityLabel.isEmpty)
        }
        #expect(HUDState.recording(.init()).offersCancel)
        #expect(!HUDState.finishing.offersCancel)
        #expect(HUDState.pasted.hidesAfter == .milliseconds(800))
        #expect(HUDState.recording(.init()).hidesAfter == nil)
    }

    @Test func announcementsAreForStartStopAndResultsNotForLevelsOrTheCountdown() {
        #expect(HUDState.recording(.init()).announcement != nil)
        #expect(HUDState.recording(.init(level: 0.9)).announcement == HUDState.recording(.init()).announcement)
        #expect(HUDState.recording(.init(loadingModel: true)).announcement == nil)
        #expect(HUDState.recording(.init(secondsLeft: 30)).announcement == nil)
        #expect(HUDState.finishing.announcement != nil)
        #expect(HUDState.pasted.announcement == HUDState.pasted.title)
    }

    @Test func theCountdownReplacesTheCancelHint() {
        #expect(HUDState.recording(.init(secondsLeft: 30)).detail?.contains("30") == true)
        #expect(HUDState.recording(.init()).detail == "Esc cancels")
    }

    @Test func theSameAnnouncementIsNotSpokenAgainWhileTheLevelMoves() {
        var gate = AnnouncementGate()
        #expect(gate.announce(.recording(.init(level: 0.1))) != nil)
        #expect(gate.announce(.recording(.init(level: 0.7))) == nil)
        #expect(gate.announce(.recording(.init(loadingModel: true))) == nil)
        #expect(gate.announce(.recording(.init(level: 0.3))) == nil)
        #expect(gate.announce(.finishing) != nil)
        #expect(gate.announce(.pasted) != nil)
        gate.reset()
        #expect(gate.announce(.recording(.init())) != nil)
    }

    @Test func theTimerFormatsMinutesAndSeconds() {
        #expect(DictationHUDView.format(0) == "0:00")
        #expect(DictationHUDView.format(65.9) == "1:05")
        #expect(DictationHUDView.format(-3) == "0:00")
    }
}
