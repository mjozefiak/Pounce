import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct ModelCardTests {
    @Test func downloadingInstallsTheModelWithoutTheNetwork() async throws {
        let rig = try SettingsRig()
        await rig.model.refresh()
        #expect(rig.model.speech.location == .missing)

        rig.model.speech.download()
        #expect(rig.model.speech.isDownloading)
        await rig.model.speech.waitForDownload()

        #expect(rig.model.speech.isInstalled)
        #expect(!rig.model.speech.isDownloading)
        #expect(rig.model.speech.errorMessage == nil)
        #expect(rig.models.downloader.callCount == 1)
        // The other card is untouched.
        #expect(rig.diarizationModels.downloader.callCount == 0)
    }

    @Test func aFailedDownloadShowsAMessageAndInstallsNothing() async throws {
        let rig = try SettingsRig()
        let broken = MeetingsModelCardModel(
            package: rig.models.package,
            manager: ModelManager(
                directory: rig.models.directory.url.appending(path: "Broken", directoryHint: .isDirectory),
                downloader: InstantDownloader(data: [:]), availableSpace: { _ in .max }),
            usage: MeetingsModelUsage { _ in false }, customFolder: { nil }, setCustomFolder: { _ in },
            pickFolder: { nil })
        broken.download()
        await broken.waitForDownload()
        #expect(!broken.isInstalled)
        #expect(broken.errorMessage != nil)
    }

    @Test func removingIsRefusedWhileAnythingHoldsTheModel() async throws {
        let rig = try SettingsRig()
        rig.model.speech.download()
        await rig.model.speech.waitForDownload()

        rig.setBusy(true)
        await rig.model.speech.refresh()
        #expect(rig.model.speech.isInUse)
        await rig.model.speech.removeModel()
        #expect(rig.model.speech.isInstalled)
        #expect(rig.model.speech.errorMessage == MeetingsModelMessages.inUse)

        // The state can change between the button's last look and the click: the action asks again.
        rig.setBusy(false)
        await rig.model.speech.removeModel()
        #expect(!rig.model.speech.isInstalled)
        #expect(rig.model.speech.errorMessage == nil)
        #expect(!rig.model.speech.isInUse)
    }

    @Test func aMeetingSessionHoldsBothModels() async throws {
        let activity = MeetingActivity()
        let usage = MeetingsModelUsage.live(activity: activity, isProcessing: { false }, leases: SpeechEngineLease())
        let package = try ModelRig().package
        #expect(await usage.isInUse(package) == false)
        activity.begin()
        #expect(activity.isActive)
        #expect(await usage.isInUse(package))
        activity.end()
        activity.end()
        #expect(!activity.isActive)
        #expect(await usage.isInUse(package) == false)
    }

    @Test func aBackgroundFinishHoldsTheModels() async throws {
        let processing = Shared(true)
        let usage = MeetingsModelUsage.live(
            activity: MeetingActivity(), isProcessing: { processing.get() }, leases: SpeechEngineLease())
        let package = try ModelRig().package
        #expect(await usage.isInUse(package))
        processing.update { $0 = false }
        #expect(await usage.isInUse(package) == false)
    }

    @Test func aSpeechLeaseHoldsOnlyItsOwnModel() async throws {
        let leases = SpeechEngineLease()
        let usage = MeetingsModelUsage.live(activity: MeetingActivity(), isProcessing: { false }, leases: leases)
        let held = try ModelRig(id: "held")
        let other = try ModelRig(id: "other")
        let lease = try await leases.acquire(
            modelID: "held", folder: held.directory.url, engine: ScriptedEngine(texts: [:]), priority: .background,
            keepWarm: { .zero })
        #expect(await usage.isInUse(held.package))
        #expect(await usage.isInUse(other.package) == false)
        await lease.release()
        #expect(await usage.isInUse(held.package) == false)
    }

    @Test func choosingAFolderVerifiesItAndSavesIt() async throws {
        let rig = try SettingsRig()
        let folder = try rig.models.makeUserFolder()
        rig.pick(folder)
        await rig.model.speech.chooseFolder()
        #expect(rig.model.speech.location == .customFolder(folder))
        #expect(rig.harness.meetingsSettings.speechModelFolder == folder)
        #expect(rig.model.speech.errorMessage == nil)

        await rig.model.speech.useDownloadedModel()
        #expect(rig.harness.meetingsSettings.speechModelFolder == nil)
        #expect(rig.model.speech.location == .missing)
    }

    @Test func anIncompleteFolderIsRefused() async throws {
        let rig = try SettingsRig()
        rig.pick(try rig.diarizationModels.makeUserFolder(complete: false))
        await rig.model.diarization.chooseFolder()
        #expect(rig.model.diarization.errorMessage != nil)
        #expect(rig.harness.meetingsSettings.diarizationModelFolder == nil)
        #expect(!rig.model.diarization.isVerifying)
    }

    @Test func theDiarizationFolderHasItsOwnKey() async throws {
        let rig = try SettingsRig()
        rig.pick(try rig.diarizationModels.makeUserFolder())
        await rig.model.diarization.chooseFolder()
        #expect(rig.harness.settings.value(forKey: "plugins.meetings.diarizationModelFolder") != nil)
        #expect(rig.harness.meetingsSettings.speechModelFolder == nil)
    }

    @Test func choosingAnotherEngineShowsThatModelsStatus() async throws {
        let rig = try SettingsRig()
        let other = try ModelRig(id: "other-engine")
        let model = MeetingsSettingsModel(
            settings: rig.harness.meetingsSettings, library: rig.library,
            privacy: MeetingsPrivacyActions(library: rig.library, spool: rig.spool, changed: {}),
            speech: rig.model.speech, diarization: rig.model.diarization, systemAudioTest: rig.model.systemAudioTest,
            notes: rig.model.notes, speechPackages: [rig.models.package, other.package], authorizer: rig.authorizer,
            listDevices: { [] },
            openURL: { _ in })
        var signals = 0
        model.onStatusChange = { signals += 1 }
        model.selectSpeechModel("other-engine")
        #expect(model.speech.package.id == "other-engine")
        #expect(rig.harness.meetingsSettings.speechModelID == "other-engine")
        // The Ready banner names the model, so the shell reads it again even when the place is unchanged.
        #expect(signals == 1)
        model.selectSpeechModel("unknown")
        #expect(model.speech.package.id == "other-engine")
        #expect(signals == 1)
        #expect(!model.usesPinnedLanguage)
    }
}

@MainActor
@Suite struct SettingsModelTests {
    @Test func theRetentionPickerWritesTheSetting() throws {
        let rig = try SettingsRig()
        #expect(rig.model.retentionDays == 90)
        #expect(MeetingsSettings.retentionDayChoices == [7, 30, 90, 180, 365, 0])
        rig.model.selectRetention(30)
        #expect(rig.harness.settings.value(forKey: "plugins.meetings.retentionDays") == .integer(30))
        #expect(rig.harness.meetingsSettings.retentionDays == 30)
        rig.model.selectRetention(0)
        #expect(rig.harness.meetingsSettings.retentionDays == 0)
    }

    @Test func theModelStartsFromTheStoredSettings() throws {
        let rig = try SettingsRig(settings: [
            "plugins.meetings.retentionDays": .integer(365), "plugins.meetings.voiceProcessing": .bool(true),
            "plugins.meetings.consentReminder": .bool(false), "plugins.meetings.inputDevice": .string("usb-1"),
        ])
        #expect(rig.model.retentionDays == 365)
        #expect(rig.model.voiceProcessing)
        #expect(!rig.model.consentReminder)
        #expect(rig.model.inputDevice == "usb-1")
    }

    @Test func theAudioTogglesWriteTheirKeys() throws {
        let rig = try SettingsRig()
        // Echo reduction is off until step 1.12 measures it.
        #expect(!rig.model.voiceProcessing)
        #expect(rig.model.consentReminder)
        rig.model.voiceProcessing = true
        rig.model.consentReminder = false
        rig.model.inputDevice = "usb-1"
        let settings = rig.harness.meetingsSettings
        #expect(settings.voiceProcessing)
        #expect(!settings.consentReminder)
        #expect(settings.inputDevice == "usb-1")
        rig.model.inputDevice = nil
        #expect(settings.inputDevice == nil)
    }

    @Test func theMicrophoneIsAskedOnlyOnTheClick() async throws {
        let rig = try SettingsRig()
        await rig.model.refresh()
        #expect(rig.model.microphone == .notDetermined)
        #expect(rig.model.devices.map(\.uid) == ["usb-1"])
        #expect(rig.authorizer.requests == 0)

        rig.model.requestMicrophone()
        try await waitForMainActor { rig.model.microphone == .granted }
        #expect(rig.authorizer.requests == 1)
    }

    @Test func theSettingsLinksPointAtThePrivacyPanes() throws {
        let opened = OpenedURLs()
        let rig = try SettingsRig(openURL: { url in opened.urls.append(url) })
        rig.model.openMicrophoneSettings()
        rig.model.openSystemAudioSettings()
        #expect(
            opened.urls.map(\.absoluteString).map { $0.split(separator: "?").last.map(String.init) } == [
                "Privacy_Microphone", "Privacy_AudioCapture",
            ])
    }

    @Test func setupProgressFollowsTheParts() {
        var progress = MeetingsSetupProgress(
            microphone: .notDetermined, systemAudioVerified: false, speechInstalled: false, diarizationInstalled: false)
        #expect(MeetingsSetupProgress.Part.allCases.allSatisfy { !progress.isDone($0) })
        #expect(!progress.isComplete)
        progress.microphone = .denied
        #expect(!progress.isDone(.microphone))
        progress.microphone = .granted
        #expect(progress.isDone(.microphone))
        progress.speechInstalled = true
        #expect(!progress.isDone(.models))
        progress.diarizationInstalled = true
        #expect(progress.isDone(.models))
        progress.systemAudioVerified = true
        #expect(progress.isComplete)
    }

    @Test func theSetupProgressOfTheModelReadsTheCards() async throws {
        let rig = try SettingsRig(access: .granted)
        await rig.model.refresh()
        #expect(rig.model.setupProgress.isDone(.microphone))
        #expect(!rig.model.setupProgress.isDone(.models))
        rig.model.speech.download()
        await rig.model.speech.waitForDownload()
        rig.model.diarization.download()
        await rig.model.diarization.waitForDownload()
        #expect(rig.model.setupProgress.isDone(.models))
    }
}

@MainActor
@Suite struct SystemAudioTestModelTests {
    @Test func startingOnlyExplainsAndPlaysNothing() throws {
        let rig = try SettingsRig()
        let test = rig.model.systemAudioTest
        #expect(test.state == .idle)
        test.begin()
        #expect(test.state == .awaitingConfirmation)
        #expect(rig.tone.played.withLock { $0 }.isEmpty)
        #expect(rig.backend.tapCount == 0)
        test.cancel()
        #expect(test.state == .idle)
        // Without the explicit step, nothing plays.
        test.playSignal()
        #expect(test.state == .idle)
        #expect(rig.tone.played.withLock { $0 }.isEmpty)
    }

    @Test func aHeardSignalWorks() async throws {
        let backend = FakeBackend()
        let player = FakeTonePlayer {
            backend.deliver(
                TapBuffer(
                    samples: Synth.sine(frequency: 880, rate: 48_000, frames: 4_800), channels: 2, sampleRate: 48_000,
                    hostTime: 1))
        }
        let test = SystemAudioTestModel(makeTest: {
            SystemAudioSelfTest(backend: backend, player: player, settle: .zero, sleeper: { _ in })
        })
        test.begin()
        test.playSignal()
        #expect(test.state == .running)
        await test.waitForTest()
        #expect(test.state == .finished(.works))
        #expect(test.isVerified)
        #expect(player.played.withLock { $0 }.count == 1)
    }

    @Test func theSystemAudioTestIsOffWhileAMeetingIsActive() async throws {
        let activity = MeetingActivity()
        let backend = FakeBackend()
        let player = FakeTonePlayer {}
        let test = SystemAudioTestModel(
            makeTest: { SystemAudioSelfTest(backend: backend, player: player, settle: .zero, sleeper: { _ in }) },
            blocked: { activity.isActive })
        activity.begin()
        #expect(test.isBlocked)
        test.begin()
        #expect(test.state == .idle)
        activity.end()
        test.begin()
        #expect(test.state == .awaitingConfirmation)
        // A meeting that starts between the two clicks keeps the signal from playing.
        activity.begin()
        test.playSignal()
        #expect(test.state == .awaitingConfirmation)
        #expect(player.played.withLock { $0 }.isEmpty)
        activity.end()
    }

    @Test func zerosMeanSilentAndNoBufferMeansUnavailable() async throws {
        let silentBackend = FakeBackend()
        let silent = SystemAudioTestModel(makeTest: {
            SystemAudioSelfTest(
                backend: silentBackend,
                player: FakeTonePlayer {
                    silentBackend.deliver(
                        TapBuffer(
                            samples: [Float](repeating: 0, count: 9_600), channels: 2, sampleRate: 48_000, hostTime: 1))
                }, settle: .zero, sleeper: { _ in })
        })
        silent.begin()
        silent.playSignal()
        await silent.waitForTest()
        #expect(silent.state == .finished(.silent))
        #expect(!silent.isVerified)

        let rig = try SettingsRig()
        let unavailable = rig.model.systemAudioTest
        unavailable.begin()
        unavailable.playSignal()
        await unavailable.waitForTest()
        #expect(unavailable.state == .finished(.unavailable))

        let denied = FakeBackend()
        denied.failNext([.permissionDenied])
        let refused = SystemAudioTestModel(makeTest: {
            SystemAudioSelfTest(backend: denied, player: FakeTonePlayer(), settle: .zero, sleeper: { _ in })
        })
        refused.begin()
        refused.playSignal()
        await refused.waitForTest()
        #expect(refused.state == .finished(.unavailable))
    }

    @Test func theVerdictMappingAndTextsAreDistinct() {
        #expect(SystemAudioTestModel.Outcome(.works) == .works)
        #expect(SystemAudioTestModel.Outcome(.silent) == .silent)
        #expect(SystemAudioTestModel.Outcome(.unavailable(.noData)) == .unavailable)
        #expect(SystemAudioTestModel.Outcome(.unavailable(.timedOut)) == .unavailable)
        let texts = Set(([.works, .silent, .unavailable] as [SystemAudioTestModel.Outcome]).map(\.message))
        #expect(texts.count == 3)
    }

    @Test func aTestCanBeRepeatedAfterTheVerdict() async throws {
        let rig = try SettingsRig()
        let test = rig.model.systemAudioTest
        test.begin()
        test.playSignal()
        await test.waitForTest()
        #expect(test.lastOutcome == .unavailable)
        test.begin()
        #expect(test.state == .awaitingConfirmation)
    }
}

@MainActor
@Suite struct PrivacyActionTests {
    private func open(_ rig: SettingsRig) throws -> MeetingsStore {
        rig.library.open()
        return try #require(rig.library.store)
    }

    @Test func clearingTheLibraryDeletesMeetingsAndSpoolsButKeepsARunningOne() async throws {
        let rig = try SettingsRig()
        let store = try open(rig)
        let ready = try store.insertMeeting(
            uuid: Sample.ids[0], startedAt: Date(), speechModelID: "m", status: .ready)
        try store.insertSegment(meetingID: ready, channel: .mic, startMs: 0, endMs: 1_000, text: "hello")
        _ = try store.insertMeeting(uuid: Sample.ids[1], startedAt: Date(), speechModelID: "m", status: .incomplete)
        _ = try store.insertMeeting(uuid: Sample.ids[2], startedAt: Date(), speechModelID: "m", status: .recording)
        for id in Sample.ids[0...3] { try rig.makeSpool(id) }

        rig.model.clearLibrary()

        #expect(try store.meetingCount() == 1)
        #expect(rig.library.meetingCount == 1)
        #expect(try store.segmentCount() == 0)
        #expect(!rig.spoolExists(Sample.ids[0]))
        #expect(!rig.spoolExists(Sample.ids[1]))
        #expect(rig.spoolExists(Sample.ids[2]))
        // A folder no meeting owns goes too.
        #expect(!rig.spoolExists(Sample.ids[3]))
        #expect(rig.model.privacyMessage != nil)
        #expect(!rig.model.privacyFailed)
        #expect(rig.changes.get() == 1)
        rig.library.close()
    }

    @Test func clearingAnEmptyLibraryIsHarmless() throws {
        let rig = try SettingsRig()
        _ = try open(rig)
        rig.model.clearLibrary()
        #expect(rig.library.meetingCount == 0)
        #expect(!rig.model.privacyFailed)
        rig.library.close()
    }

    @Test func deletingTemporaryRecordingsRemovesTheAudioOfInterruptedMeetingsOnly() async throws {
        let rig = try SettingsRig()
        let store = try open(rig)
        let incomplete = try store.insertMeeting(
            uuid: Sample.ids[0], startedAt: Date(), speechModelID: "m", status: .incomplete)
        try store.insertSegment(meetingID: incomplete, channel: .mic, startMs: 0, endMs: 1_000, text: "kept")
        let missingFolder = try store.insertMeeting(
            uuid: Sample.ids[1], startedAt: Date(), speechModelID: "m", status: .incomplete)
        let processing = try store.insertMeeting(
            uuid: Sample.ids[2], startedAt: Date(), speechModelID: "m", status: .processing)
        let ready = try store.insertMeeting(uuid: Sample.ids[3], startedAt: Date(), speechModelID: "m", status: .ready)
        for id in [Sample.ids[0], Sample.ids[2], Sample.ids[3]] { try rig.makeSpool(id) }

        rig.model.deleteTemporaryRecordings()

        #expect(!rig.spoolExists(Sample.ids[0]))
        #expect(rig.spoolExists(Sample.ids[2]))
        #expect(rig.spoolExists(Sample.ids[3]))
        #expect(try store.audioState(of: incomplete) == .deleted)
        #expect(try store.audioState(of: missingFolder) == .deleted)
        #expect(try store.audioState(of: processing) == .spool)
        #expect(try store.audioState(of: ready) == .spool)
        // The transcript stays.
        #expect(try store.segmentCount(meetingID: incomplete) == 1)
        #expect(try store.meetingCount() == 4)
        #expect(!rig.model.privacyFailed)
        rig.library.close()
    }

    @Test func nothingHappensWhileTheLibraryIsClosed() throws {
        let rig = try SettingsRig()
        #expect(!rig.model.canChangeLibrary)
        try rig.makeSpool(Sample.ids[0])
        rig.model.clearLibrary()
        rig.model.deleteTemporaryRecordings()
        #expect(rig.spoolExists(Sample.ids[0]))
        rig.library.open()
        #expect(rig.model.canChangeLibrary)
        rig.library.close()
    }
}

@MainActor
@Suite struct MeetingsContributionTests {
    @Test func theSetupStepIsContributedAndSkippable() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        let steps = plugin.onboardingSteps
        #expect(steps.map(\.id) == ["meetings.setup"])
        #expect(steps.first?.symbolName.isEmpty == false)
    }

    @Test func theSettingsPaneExistsAndOnlyTheSystemAudioPermissionGetsATest() throws {
        let harness = try MeetingsHarness()
        let plugin = MeetingsPlugin(context: harness.context)
        #expect(plugin.settingsPane() != nil)
        #expect(plugin.permissionAccessory(for: .systemAudioRecording) != nil)
        #expect(plugin.permissionAccessory(for: .microphone) == nil)
        #expect(plugin.permissionAccessory(for: .accessibility) == nil)
        // Step 1.10 added the command, so the shortcut row has its recorder.
        #expect(plugin.commands.contains { $0.id == MeetingsUI.recordCommandID })
    }

    @Test func everyMeetingsSettingsStringHasEnglishAndValidPolishForms() throws {
        let root = TestPaths.repoRoot
        let data = try Data(contentsOf: root.appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        let keys = [
            "Test System Audio", "Play Test Signal", "Clear Library…", "Delete Temporary Recordings…",
            "Remove Model", "Until I delete them", "Removed %lld meetings and their audio.",
            "System audio works. Lintel heard its own test signal.", "Delete older meetings?",
            "Delete Older Meetings", "%lld recordings could not be deleted. Close anything using them and try again.",
            "%lld meetings are older than the new limit and are deleted now. This can’t be undone.",
            "Deleted the audio of %lld interrupted meetings.", "%lld days",
        ]
        for key in keys {
            let localizations = try #require(strings[key]?["localizations"] as? [String: Any], "\(key)")
            #expect(localizations["en"] != nil && localizations["pl"] != nil, "\(key)")
            func text(_ language: String) -> [String: String] {
                guard let entry = localizations[language] as? [String: Any] else { return [:] }
                if let unit = (entry["stringUnit"] as? [String: Any])?["value"] as? String { return ["": unit] }
                let plural = ((entry["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]]) ?? [:]
                return plural.compactMapValues { ($0["stringUnit"] as? [String: Any])?["value"] as? String }
            }
            let english = text("en")
            let polish = text("pl")
            #expect(!english.isEmpty && !polish.isEmpty && !polish.values.contains(""), "\(key)")
            if key.contains("%lld"), Set(polish.keys) != [""] {
                // Polish needs one, few, many and other; every form keeps the number.
                #expect(Set(polish.keys) == ["one", "few", "many", "other"], "\(key)")
                #expect(polish.values.allSatisfy { $0.contains("%lld") }, "\(key)")
                #expect(Set(english.keys) == ["one", "other"], "\(key)")
            }
        }
    }

    @Test func modelsLiveInTheSharedModelsFolder() throws {
        #expect(MeetingsUI.speechDirectoryName == "speech")
        #expect(MeetingsUI.diarizationDirectoryName == "diarization")
        #expect(MeetingsUI.onboardingStepID == "meetings.setup")
    }
}

/// Polls on the main actor until `condition` holds (the microphone prompt answers on another task).
@MainActor
func waitForMainActor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

@MainActor
final class OpenedURLs {
    var urls: [URL] = []
}

@MainActor
@Suite struct RetentionPickerTests {
    private func seed(_ rig: SettingsRig, ageDays: [Double]) throws -> [Int64] {
        rig.library.open()
        let store = try #require(rig.library.store)
        return try ageDays.enumerated().map { index, days in
            try store.insertMeeting(
                uuid: Sample.ids[index], startedAt: Date().addingTimeInterval(-days * 86_400), speechModelID: "m",
                status: .ready)
        }
    }

    @Test func aShorterPeriodThatDeletesMeetingsWaitsForConfirmationAndThenAppliesAtOnce() async throws {
        let rig = try SettingsRig()
        _ = try seed(rig, ageDays: [100, 40, 2])
        let store = try #require(rig.library.store)
        rig.model.selectRetention(30)
        #expect(rig.model.pendingRetention == .init(days: 30, affected: 2))
        #expect(rig.model.retentionDays == 90)
        #expect(try store.meetingCount() == 3)

        rig.model.cancelRetention()
        #expect(rig.model.pendingRetention == nil)
        #expect(rig.harness.meetingsSettings.retentionDays == 90)

        rig.model.selectRetention(30)
        await rig.model.confirmRetention()?.value
        #expect(rig.harness.meetingsSettings.retentionDays == 30)
        #expect(try store.meetingCount() == 1)
        #expect(rig.library.meetingCount == 1)
        #expect(rig.model.privacyMessage != nil)
        rig.library.close()
    }

    @Test func aLongerOrHarmlessPeriodAppliesWithoutAsking() throws {
        let rig = try SettingsRig()
        _ = try seed(rig, ageDays: [100, 2])
        rig.model.selectRetention(365)
        #expect(rig.model.pendingRetention == nil && rig.model.retentionDays == 365)
        rig.model.selectRetention(0)
        #expect(rig.model.retentionDays == 0)
        // From "never" to a period that expires one meeting asks; one that expires none does not.
        rig.model.selectRetention(180)
        #expect(rig.model.pendingRetention == nil && rig.model.retentionDays == 180)
        rig.model.selectRetention(30)
        #expect(rig.model.pendingRetention?.affected == 1)
        rig.library.close()
    }

    @Test func aMeetingBeingFinishedIsNotCountedOrDeleted() async throws {
        let rig = try SettingsRig()
        let ids = try seed(rig, ageDays: [100])
        let store = try #require(rig.library.store)
        try store.setStatus(ids[0], status: .incomplete)
        #expect(rig.library.meetingsExpiring(afterDays: 30) == 1)
        let protected: Set<Int64> = Set(ids)
        #expect(try store.expiredMeetingCount(cutoff: Date(), excluding: protected) == 0)
        #expect(try store.applyRetention(cutoff: Date(), excluding: protected).isEmpty)
        #expect(try store.meetingCount() == 1)
        rig.library.close()
    }

    @Test func aStoredValueOutsideTheChoicesIsAddedInOrder() throws {
        let rig = try SettingsRig(settings: ["plugins.meetings.retentionDays": .integer(45)])
        #expect(rig.model.retentionChoices() == [7, 30, 45, 90, 180, 365, 0])
        #expect(MeetingsSettingsModel.choices([7, 30, 0], including: 30) == [7, 30, 0])
        #expect(MeetingsSettingsModel.choices([7, 30], including: 400) == [7, 30, 400])
    }
}
