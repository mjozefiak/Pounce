import Foundation
import Testing

@testable import MeetingsPlugin

/// Step 3.4: Clear Library, Delete Temporary Recordings and a shorter retention asks before it deletes, with a verb on the confirm button, in English and Polish.
@Suite struct MeetingsConfirmationTests {
    private func expectTranslated(_ key: String) throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Localizable.xcstrings")
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any], "\(key) is not in the catalog")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        #expect(localizations["en"] != nil && localizations["pl"] != nil, "\(key) needs en and pl")
    }

    @Test func everyDestructiveActionHasWordsAndAVerb() throws {
        for resource in [
            MeetingsConfirmations.clearLibrary.prompt, MeetingsConfirmations.clearLibrary.detail,
            MeetingsConfirmations.clearLibrary.confirmTitle,
        ] { try expectTranslated(resource.key) }
        #expect(MeetingsConfirmations.clearLibrary.confirmTitle.key == "Delete All Meetings")
        for resource in [
            MeetingsConfirmations.deleteRecordings.prompt, MeetingsConfirmations.deleteRecordings.detail,
            MeetingsConfirmations.deleteRecordings.confirmTitle,
        ] { try expectTranslated(resource.key) }
        #expect(MeetingsConfirmations.deleteRecordings.confirmTitle.key == "Delete Recordings")
        for resource in [
            MeetingsConfirmations.olderMeetings(count: 3).prompt, MeetingsConfirmations.olderMeetings(count: 3).detail,
            MeetingsConfirmations.olderMeetings(count: 3).confirmTitle,
        ] { try expectTranslated(resource.key) }
        #expect(MeetingsConfirmations.olderMeetings(count: 3).confirmTitle.key == "Delete Older Meetings")
    }
}
