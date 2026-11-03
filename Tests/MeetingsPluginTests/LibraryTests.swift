import Foundation
import GRDB
import PounceKit
import PouncePersistence
import PounceSpeech
import Testing

@testable import MeetingsPlugin

private func mode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

@MainActor
@Suite struct MeetingKeyTests {
    @Test func theKeysUseTheDocumentedServiceAndInfos() throws {
        #expect(MeetingKeyStore.service == "app.pounce.meetings")
        let master = Data(repeating: 7, count: 32)
        let keys = try #require(MasterKeys(master: master))
        let meeting = MeetingKeys(keys)
        #expect(meeting.spool.withUnsafeBytes { Data($0) } == keys.derived(info: "spool").withUnsafeBytes { Data($0) })
        #expect(
            meeting.spool.withUnsafeBytes { Data($0) } != keys.derived(info: "sqlcipher").withUnsafeBytes { Data($0) })
        #expect(meeting.description == "MeetingKeys(redacted)")
        #expect("\(meeting)" == "MeetingKeys(redacted)")
    }

    @Test func aMalformedKeyIsReportedNotReplaced() throws {
        let harness = try MeetingsHarness()
        try harness.keychain.addGenericPassword(
            Data(repeating: 1, count: 5), service: "app.pounce.meetings", account: "master-key")
        let library = harness.library()
        library.open()
        #expect(library.status == .unavailable(.malformedKey))
        #expect(harness.keychain.itemNames == ["app.pounce.meetings/master-key"])
    }
}

@MainActor
@Suite struct MeetingsLibraryTests {
    @Test func openingCreatesTheKeyAndAPrivateEncryptedLibrary() throws {
        let harness = try MeetingsHarness()
        let library = harness.library()
        #expect(library.status == .closed)
        library.open()
        #expect(library.status == .ready)
        #expect(library.canRecord)
        #expect(library.resetArchive == nil)
        #expect(harness.keychain.itemNames == ["app.pounce.meetings/master-key"])
        #expect(try mode(harness.pluginDirectory) == 0o700)
        #expect(try mode(harness.pluginDirectory.appending(path: "meetings.sqlite")) == 0o600)
        library.close()
        #expect(library.status == .closed)
        #expect(!library.canRecord)
    }

    @Test func aMissingKeyArchivesTheUnreadableLibraryAndStartsAgain() throws {
        let harness = try MeetingsHarness()
        let stamp = Date(timeIntervalSince1970: 1_000_000)
        let first = harness.library(now: { stamp })
        first.open()
        let store = try #require(first.store)
        try store.insertMeeting(uuid: "a", startedAt: stamp, speechModelID: "m")
        first.close()

        try harness.keychain.deleteGenericPassword(service: "app.pounce.meetings", account: "master-key")
        let second = harness.library(now: { stamp })
        second.open()

        #expect(second.status == .ready)
        #expect(try second.store?.meetingCount() == 0)
        let archive = try #require(second.resetArchive)
        #expect(archive.lastPathComponent == "meetings.sqlite.unreadable-\(EncryptedDatabaseOpener.stamp(stamp))")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(harness.keychain.itemNames == ["app.pounce.meetings/master-key"])
        second.close()

        // The archive is kept for 30 days and then purged.
        let opener = EncryptedDatabaseOpener(
            directory: harness.pluginDirectory, databaseFileName: MeetingsStore.fileName,
            keyStore: MeetingKeyStore(keychain: harness.keychain).master)
        #expect(opener.purgeOldArchives(now: stamp.addingTimeInterval(29 * 86_400)) == 0)
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(opener.purgeOldArchives(now: stamp.addingTimeInterval(31 * 86_400)) >= 1)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
    }

    @Test(arguments: [
        KeychainError.interactionNotAllowed, .accessDenied, .unexpected(status: -25_299),
    ])
    func anyOtherKeychainErrorDisablesTheLibraryAndDeletesNothing(error: KeychainError) throws {
        let harness = try MeetingsHarness()
        let first = harness.library()
        first.open()
        try first.store?.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m")
        first.close()
        let file = harness.pluginDirectory.appending(path: "meetings.sqlite")
        let before = try Data(contentsOf: file)

        harness.keychain.failReads(with: error)
        let second = harness.library()
        second.open()

        #expect(second.status == .unavailable(KeyStoreError(error)))
        #expect(!second.canRecord)
        #expect(second.store == nil)
        #expect(second.resetArchive == nil)
        #expect(try Data(contentsOf: file) == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: harness.pluginDirectory.path)
        #expect(!names.contains { $0.contains(".unreadable-") })
        #expect(harness.keychain.itemNames == ["app.pounce.meetings/master-key"])
        #expect(harness.keychain.deleteCount == 0)

        // Once the Keychain answers again, the same library opens with its data.
        harness.keychain.failReads(with: nil)
        second.open()
        #expect(second.status == .ready)
        #expect(try second.store?.meetingCount() == 1)
    }

    @Test func aDatabaseThatDoesNotOpenWithTheKeyFailsWithoutDeletingIt() throws {
        let harness = try MeetingsHarness()
        let first = harness.library()
        first.open()
        first.close()
        let file = harness.pluginDirectory.appending(path: "meetings.sqlite")
        try harness.keychain.deleteGenericPassword(service: "app.pounce.meetings", account: "master-key")
        try harness.keychain.addGenericPassword(
            Data(repeating: 3, count: 32), service: "app.pounce.meetings", account: "master-key")
        let second = harness.library()
        second.open()
        #expect(second.status == .failed)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: harness.pluginDirectory.path)
        #expect(!names.contains { $0.contains(".unreadable-") })
    }

    @Test func retentionUsesTheSettingAndKeepsEverythingWhenUnlimited() async throws {
        let now = Date(timeIntervalSince1970: 500 * 86_400)
        let harness = try MeetingsHarness()
        let spool = RecordingSpool()
        let library = harness.library(now: { now }, spool: spool)
        library.open()
        let store = try #require(library.store)
        for (uuid, age) in [("a", 20.0), ("b", 60.0), ("c", 200.0)] {
            let id = try store.insertMeeting(
                uuid: uuid, startedAt: now.addingTimeInterval(-age * 86_400), speechModelID: "m")
            try store.setStatus(id, status: .ready)
        }
        library.refreshCount()
        #expect(library.meetingCount == 3)

        // The default is 90 days.
        #expect(harness.meetingsSettings.retentionDays == 90)
        #expect(await library.applyRetention() == 1)
        #expect(library.meetingCount == 2)

        harness.meetingsSettings.setRetentionDays(30)
        #expect(await library.applyRetention() == 1)
        #expect(library.meetingCount == 1)

        harness.meetingsSettings.setRetentionDays(0)
        #expect(await library.applyRetention() == 0)
        #expect(library.meetingCount == 1)
        #expect(spool.state.withLock { $0.removedForMeetings } == ["c", "b"])
    }

    @Test func clearRemovesEveryMeetingButKeepsTheKeyAndTheDatabase() throws {
        let harness = try MeetingsHarness()
        let library = harness.library()
        library.open()
        try library.store?.insertMeeting(uuid: "a", startedAt: Date(), speechModelID: "m", status: .ready)
        library.refreshCount()
        #expect(library.meetingCount == 1)
        let privacy = MeetingsPrivacyActions(
            library: library, spool: SpoolStorage(pluginDirectory: harness.pluginDirectory), changed: {})
        #expect(try privacy.clearLibrary().removed == 1)
        #expect(library.meetingCount == 0)
        #expect(harness.keychain.itemNames == ["app.pounce.meetings/master-key"])
        #expect(FileManager.default.fileExists(atPath: harness.pluginDirectory.appending(path: "meetings.sqlite").path))
    }
}

@MainActor
@Suite struct MeetingsSettingsTests {
    @Test func defaultsMatchTheSpecTable() throws {
        let settings = try MeetingsHarness().meetingsSettings
        #expect(settings.speechModelID == "parakeet-ultra")
        #expect(settings.speechLanguage == "pl")
        #expect(settings.speechModelFolder == nil)
        #expect(settings.inputDevice == nil)
        #expect(settings.voiceProcessing == false)
        #expect(settings.diarization == true)
        #expect(settings.consentReminder == true)
        #expect(settings.notesEnabled == false)
        #expect(settings.builtInLLMModel.id == LLMModelCatalog.defaultModel.id)
        #expect(settings.notesChunkTokens == 3_000)
        #expect(settings.notesReduceInputTokens == 4_500)
        #expect(settings.suggestMeetings == false)
        #expect(settings.suggestMutedBundleIDs.isEmpty)
        #expect(settings.suggestExtraBundleIDs.isEmpty)
        #expect(settings.retentionDays == 90)
        #expect(settings.orphanAudioDays == 7)
    }

    @Test func aStoredLargeModelFallsBackToTheDefaultWhenTheMemoryIsTooSmall() throws {
        let harness = try MeetingsHarness(settings: [
            "plugins.meetings.builtInLLMModel": .string(LLMModelCatalog.qwen3Large.id)
        ])
        let big = MeetingsSettings(harness.context.settings, physicalMemory: 64 << 30)
        let small = MeetingsSettings(harness.context.settings, physicalMemory: 16 << 30)
        #expect(big.builtInLLMModel.id == LLMModelCatalog.qwen3Large.id)
        #expect(small.builtInLLMModel.id == LLMModelCatalog.defaultModel.id)
    }

    @Test func storedValuesAreReadUnderTheMeetingsPrefix() throws {
        let harness = try MeetingsHarness(settings: [
            "plugins.meetings.speechModel": .string("whisper"),
            "plugins.meetings.speechLanguage": .string("en"),
            "plugins.meetings.speechModelFolder": .string("/tmp/model"),
            "plugins.meetings.inputDevice": .string("uid-1"),
            "plugins.meetings.voiceProcessing": .bool(true),
            "plugins.meetings.diarization": .bool(false),
            "plugins.meetings.consentReminder": .bool(false),
            "plugins.meetings.notesEnabled": .bool(true),
            "plugins.meetings.builtInLLMModel": .string("no-such-model"),
            "plugins.meetings.notesChunkTokens": .integer(2_000),
            "plugins.meetings.notesReduceInputTokens": .integer(3_000),
            "plugins.meetings.suggestMeetings": .bool(true),
            "plugins.meetings.suggestMutedBundleIDs": .stringArray(["a.b"]),
            "plugins.meetings.suggestExtraBundleIDs": .stringArray(["c.d.e"]),
            "plugins.meetings.retentionDays": .integer(0),
            "plugins.meetings.orphanAudioDays": .integer(3),
        ])
        let settings = harness.meetingsSettings
        #expect(settings.speechModelID == "whisper")
        #expect(settings.speechLanguage == "en")
        #expect(settings.speechModelFolder?.path == "/tmp/model")
        #expect(settings.inputDevice == "uid-1")
        #expect(settings.voiceProcessing)
        #expect(!settings.diarization)
        #expect(!settings.consentReminder)
        #expect(settings.notesEnabled)
        // A stored id that is not in the catalog means the default model.
        #expect(settings.builtInLLMModel.id == LLMModelCatalog.defaultModel.id)
        #expect(settings.notesChunkTokens == 2_000)
        #expect(settings.notesReduceInputTokens == 3_000)
        #expect(settings.suggestMeetings)
        #expect(settings.suggestMutedBundleIDs == ["a.b"])
        #expect(settings.suggestExtraBundleIDs == ["c.d.e"])
        #expect(settings.retentionDays == 0)
        #expect(settings.orphanAudioDays == 3)
    }

    @Test func settersWriteTheSameKeysAndKeepTheDictationNamespaceUntouched() throws {
        let harness = try MeetingsHarness()
        let settings = harness.meetingsSettings
        settings.setRetentionDays(180)
        settings.setSpeechLanguage("en")
        settings.setSuggestMeetings(true)
        #expect(harness.settings.value(forKey: "plugins.meetings.retentionDays") == .integer(180))
        #expect(harness.settings.value(forKey: "plugins.meetings.speechLanguage") == .string("en"))
        #expect(harness.settings.value(forKey: "plugins.meetings.suggestMeetings") == .bool(true))
        #expect(harness.settings.value(forKey: "plugins.dictation.speechLanguage") == nil)
        settings.setRetentionDays(-5)
        #expect(settings.retentionDays == 0)
    }
}
