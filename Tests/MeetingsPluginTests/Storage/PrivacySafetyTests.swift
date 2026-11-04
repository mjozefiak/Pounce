import Foundation
import LintelKit
import LintelSpeech
import Synchronization
import Testing

@testable import MeetingsPlugin

private let words: [Int: String] = [11: "Pierwsza wypowiedź", 12: "Druga wypowiedź"]

/// The destructive actions must never take the row or the audio of a meeting that is being finished.
@MainActor
@Suite struct PrivacyDuringFinishTests {
    @Test func clearLibraryAndDeleteTemporaryRecordingsSkipAMeetingBeingFinished() async throws {
        let rig = try RecoveryRig(texts: words)
        let track = TrackScript.build([(1, 11, 3), (4, 12, 3)], tail: 1)
        let busy = try rig.seed(.incomplete, mic: track, stored: [(.mic, 16_000..<64_000, words[11]!)])
        let idle = try rig.seed(.incomplete, mic: track)
        let ready = try rig.seed(.ready, mic: track)
        let library = rig.library(resumer: rig.resumerFactory(mic: track))
        library.open()
        let store = try #require(library.store)
        let privacy = MeetingsPrivacyActions(library: library, spool: rig.spool, changed: {})
        rig.engine.gate.close()

        let handle = try #require(library.finish(meetingID: busy.id))
        let finishing = Task { await handle.outcome }
        let engine = rig.engine
        #expect(await engine.transcribing.wait { engine.entered >= 1 })
        #expect(library.isProcessing)
        #expect(library.activeResumes == [busy.id])

        let temporary = try privacy.deleteTemporaryRecordings()
        #expect(temporary.removed == 1)
        #expect(try store.status(of: busy.id) == .processing)
        #expect(try store.audioState(of: busy.id) == .spool)
        #expect(rig.spoolExists(busy.uuid))
        #expect(!rig.spoolExists(idle.uuid))
        #expect(try store.audioState(of: idle.id) == .deleted)

        let cleared = try privacy.clearLibrary()
        #expect(cleared.removed == 2)
        #expect(try store.status(of: busy.id) == .processing)
        #expect(rig.spoolExists(busy.uuid))
        #expect(try store.meetingCount() == 1)
        #expect(!rig.spoolExists(ready.uuid))

        // Retention leaves it alone too.
        #expect(await library.applyRetention() == 0)
        #expect(try store.meetingCount() == 1)

        engine.gate.open()
        #expect(await finishing.value == .ready)
        #expect(try store.status(of: busy.id) == .ready)
        #expect(!library.isProcessing)
        library.close()
    }
}

@MainActor
@Suite struct PrivacyOrphanSweepTests {
    @Test func aStartingSessionsFolderSurvivesAndOnlyUUIDDirectoriesAreSwept() throws {
        let rig = try SettingsRig()
        rig.library.open()
        let store = try #require(rig.library.store)
        let owned = Sample.ids[0].uppercased()
        _ = try store.insertMeeting(uuid: owned, startedAt: Date(), speechModelID: "m", status: .ready)
        _ = try store.insertMeeting(uuid: Sample.ids[1], startedAt: Date(), speechModelID: "m", status: .recording)
        try rig.makeSpool(Sample.ids[2])  // a folder whose row is about to be inserted
        try rig.makeSpool(Sample.ids[3])  // a real orphan, but only once nothing is starting
        let stray = rig.spool.root.appending(path: "notes.txt")
        try Data("x".utf8).write(to: stray)
        let named = rig.spool.root.appending(path: "not-a-uuid", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
        let target = rig.harness.pluginDirectory.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = rig.spool.root.appending(path: Sample.ids[4])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        rig.activity.begin()
        rig.model.clearLibrary()
        #expect(rig.spoolExists(Sample.ids[2]))
        #expect(rig.spoolExists(Sample.ids[3]))

        rig.activity.end()
        rig.model.clearLibrary()
        #expect(!rig.spoolExists(Sample.ids[2]))
        #expect(!rig.spoolExists(Sample.ids[3]))
        #expect(FileManager.default.fileExists(atPath: stray.path))
        #expect(FileManager.default.fileExists(atPath: named.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(!rig.model.privacyFailed)
        rig.library.close()
    }

    @Test func aFolderThatCannotBeRemovedIsReportedAsAFailure() throws {
        let rig = try SettingsRig()
        rig.library.open()
        let store = try #require(rig.library.store)
        let gone = try store.insertMeeting(
            uuid: Sample.ids[0], startedAt: Date(), speechModelID: "m", status: .ready)
        _ = gone
        try rig.makeSpool(Sample.ids[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.spool.root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.spool.root.path)
        }

        rig.model.clearLibrary()

        #expect(rig.model.privacyFailed)
        #expect(rig.spoolExists(Sample.ids[0]))
        #expect(try store.meetingCount() == 0)
        rig.library.close()
    }

    @Test func aTemporaryRecordingThatCannotBeRemovedKeepsItsAudioStateAndIsReported() throws {
        let rig = try SettingsRig()
        rig.library.open()
        let store = try #require(rig.library.store)
        let id = try store.insertMeeting(
            uuid: Sample.ids[0], startedAt: Date(), speechModelID: "m", status: .incomplete)
        try rig.makeSpool(Sample.ids[0])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: rig.spool.root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rig.spool.root.path)
        }

        rig.model.deleteTemporaryRecordings()

        #expect(rig.model.privacyFailed)
        #expect(try store.audioState(of: id) == .spool)
        rig.library.close()
    }
}

@MainActor
@Suite struct ModelRemovalRaceTests {
    private func card(_ rig: ModelRig, usage: MeetingsModelUsage) -> MeetingsModelCardModel {
        MeetingsModelCardModel(
            package: rig.package, manager: rig.manager, usage: usage, customFolder: { nil },
            setCustomFolder: { _ in }, pickFolder: { nil })
    }

    @Test func aUserThatAppearsAfterTheFirstCheckStopsTheRemoval() async throws {
        let rig = try ModelRig()
        let asks = Shared(0)
        let usage = MeetingsModelUsage { _ in
            asks.update { $0 += 1 }
            // The first look (the button's) says free; the manager's look right before deleting finds a user.
            return asks.get() >= 2
        }
        let model = card(rig, usage: usage)
        model.download()
        await model.waitForDownload()
        #expect(model.isInstalled)

        await model.removeModel()

        #expect(model.isInstalled)
        #expect(model.errorMessage == MeetingsModelMessages.inUse)
        #expect(asks.get() >= 2)
    }

    @Test func aReservationIsHeldForTheWholeRemovalAndReleasedAfterwards() async throws {
        let rig = try ModelRig()
        let activity = MeetingActivity()
        let seen = Shared<[Bool]>([])
        let live = MeetingsModelUsage.live(activity: activity, isProcessing: { false }, leases: SpeechEngineLease())
        let usage = MeetingsModelUsage(
            isInUse: { package in
                seen.update { $0.append(activity.isRemovingModel) }
                return await live.isInUse(package)
            }, reserveRemoval: live.reserveRemoval)
        let model = card(rig, usage: usage)
        model.download()
        await model.waitForDownload()

        await model.removeModel()

        #expect(!model.isInstalled)
        // Asked once before the reservation (button state), once inside the delete under it.
        #expect(seen.get().first == false && seen.get().contains(true))
        #expect(!activity.isRemovingModel)
        // A session that began is seen by the live usage and keeps the model.
        activity.begin()
        let again = card(try ModelRig(), usage: live)
        #expect(await live.isInUse(again.package))
    }

    @Test func theManagerRefusesToDeleteWhenTheCallbackSaysInUse() async throws {
        let rig = try ModelRig()
        try await rig.manager.install(rig.package) { _ in }
        #expect(try await rig.manager.delete(rig.package, unless: { true }) == false)
        #expect(await rig.manager.location(of: rig.package).folder != nil)
        #expect(try await rig.manager.delete(rig.package, unless: { false }))
        #expect(await rig.manager.location(of: rig.package).folder == nil)
    }
}

@MainActor
@Suite struct ChooseFolderRaceTests {
    private func rig(picks: Shared<Int>) throws -> (SettingsRig, URL) {
        let rig = try SettingsRig()
        let folder = try rig.models.makeUserFolder()
        rig.pick(folder)
        _ = picks
        return (rig, folder)
    }

    /// Lets the started task run until it is verifying. One `Task.yield()` is not enough under parallel load,
    /// when the task has not been scheduled yet.
    private static func untilVerifying(_ card: MeetingsModelCardModel) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !card.isVerifying, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func aResultForAnotherPackageIsDropped() async throws {
        let (rig, _) = try rig(picks: Shared(0))
        let card = rig.model.speech
        let other = rig.diarizationModels.package
        let task = Task { await card.chooseFolder() }
        await Self.untilVerifying(card)
        #expect(card.isVerifying)
        card.use(other)
        await task.value
        #expect(rig.harness.meetingsSettings.speechModelFolder == nil)
        #expect(card.errorMessage == nil)
        #expect(!card.isVerifying)
    }

    @Test func aSecondChooseWhileVerifyingDoesNothing() async throws {
        let (rig, folder) = try rig(picks: Shared(0))
        let card = rig.model.speech
        let first = Task { await card.chooseFolder() }
        await Self.untilVerifying(card)
        #expect(card.isVerifying)
        rig.pick(nil)
        await card.chooseFolder()
        #expect(card.isVerifying)
        await first.value
        #expect(rig.harness.meetingsSettings.speechModelFolder == folder)
    }

    @Test func theLoadPathAsksForTheFolderNowNotTheStoredSetting() async throws {
        let (rig, folder) = try rig(picks: Shared(0))
        let card = rig.model.speech
        await card.chooseFolder()
        #expect(await card.loadableFolder() == folder)
        // The user moved the model away afterwards: the setting still names the folder, the load path must not.
        try FileManager.default.removeItem(at: folder.appending(path: "weights.bin"))
        #expect(rig.harness.meetingsSettings.speechModelFolder == folder)
        #expect(await card.loadableFolder() == nil)
    }
}
