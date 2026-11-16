import Foundation
import GRDB
import LintelKit
import Testing

@testable import MeetingsPlugin

@MainActor
@Suite struct ConsentCopyTests {
    // MARK: HUD state

    @Test func theConsentReminderOffersCopyMessageNextToStop() {
        var recording = MeetingHUDState.Recording()
        recording.showsConsent = true
        let state = MeetingHUDState.recording(recording)
        #expect(state.actions == [.copyConsentText, .stop])
        #expect(state.title(for: .copyConsentText) == "Copy message")
        recording.showsConsent = false
        #expect(MeetingHUDState.recording(recording).actions == [.stop])
    }

    // MARK: Controller

    @Test func copyMessagePutsTheSentenceOnThePasteboardAndStoresOnlyTheTime() async throws {
        let rig = try ControllerRig()
        let store = try #require(rig.library.store)
        let id = try store.insertMeeting(uuid: "u-consent", startedAt: Date(), speechModelID: "m")
        rig.behaviour.meetingID = id
        await rig.startRecording()
        rig.controller.perform(.copyConsentText)
        #expect(rig.pasteboard.string() == MeetingConsentText.sentence)
        #expect(rig.pasteboard.string()?.isEmpty == false)
        let document = try #require(try store.loadDocument(id: id))
        #expect(document.consentTextCopiedAt == Date(timeIntervalSince1970: 1_800_000_000))
        // A second click keeps the first time.
        rig.consentClock = Date(timeIntervalSince1970: 1_800_000_600)
        rig.controller.perform(.copyConsentText)
        #expect(try store.loadDocument(id: id)?.consentTextCopiedAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aMeetingWithoutACopyHasNoTime() async throws {
        let rig = try ControllerRig()
        let store = try #require(rig.library.store)
        let id = try store.insertMeeting(uuid: "u-none", startedAt: Date(), speechModelID: "m")
        #expect(try store.loadDocument(id: id)?.consentTextCopiedAt == nil)
    }

    // MARK: Window line

    @Test func theWindowShowsTheCopyTimeOrNothing() async throws {
        let rig = try ControllerRig()
        let store = try #require(rig.library.store)
        let id = try store.insertMeeting(uuid: "u-line", startedAt: Date(), speechModelID: "m")
        var document = try #require(try store.loadDocument(id: id))
        #expect(MeetingWindowView.consentLine(document) == nil)
        document.consentTextCopiedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let line = try #require(MeetingWindowView.consentLine(document))
        #expect(line.hasPrefix("Message copied at "))
        #expect(!line.localizedCaseInsensitiveContains("notified"))
    }

    // MARK: Migration

    @Test func theMigrationAddsANullColumnToOlderDatabases() throws {
        let queue = try DatabaseQueue()
        let migrator = MeetingsStore.migrator
        try migrator.migrate(queue, upTo: "v1-meetings")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO meeting (uuid, started_at, status) VALUES ('old', 1000, 'ready')")
        }
        try migrator.migrate(queue)
        let value = try queue.read { db in
            try Row.fetchOne(db, sql: "SELECT consent_text_copied_at AS c FROM meeting WHERE uuid = 'old'")
        }
        let row = try #require(value)
        #expect((row["c"] as Int64?) == nil)
        #expect(try queue.read { try migrator.appliedIdentifiers($0) } == ["v1-meetings", "v2-consent"])
    }

    // MARK: Language

    @Test func theCatalogHasNoClaimsOfInvisibility() throws {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: root.appending(path: "Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        let forbidden = [
            "invisible", "undetectable", "niewidoczn", "niewykrywaln", "nikt się nie dowie", "no one will know",
            "nobody will know", "powiadomiono uczestników", "participants were notified",
        ]
        var checked = 0
        for (key, value) in strings {
            let entry = value as? [String: Any]
            let comment = (entry?["comment"] as? String) ?? ""
            guard (key + comment).localizedCaseInsensitiveContains("meeting") || comment.contains("consent") else {
                continue
            }
            var texts = [key]
            for (_, localization) in (entry?["localizations"] as? [String: Any]) ?? [:] {
                if let value = ((localization as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
                {
                    texts.append(value)
                }
            }
            checked += 1
            for text in texts {
                for word in forbidden {
                    #expect(!text.localizedCaseInsensitiveContains(word), "\(key) contains \(word)")
                }
            }
        }
        #expect(checked > 20)
        let consent = try #require(strings[MeetingConsentTextKey.sentence] as? [String: Any])
        let localizations = try #require(consent["localizations"] as? [String: Any])
        #expect(localizations["en"] != nil && localizations["pl"] != nil)
    }
}

private enum MeetingConsentTextKey {
    static let sentence = "I'm recording this meeting with Lintel to take notes. Tell me if you object."
}
