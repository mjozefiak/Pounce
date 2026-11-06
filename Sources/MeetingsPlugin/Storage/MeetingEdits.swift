import Foundation
import LintelCore

/// The edits a person makes to a meeting that must stay in the owner: the title, a speaker's name and "this is
/// me". Both the meeting window and the Notes workspace (`MeetingNoteSource`) call them, so the rules (what
/// counts as a blank name, which meetings accept "this is me", that the notes become `stale`) live once.
enum MeetingEdits {
    enum Failure: Error, Equatable {
        /// There is no such meeting or speaker.
        case notFound
        /// The edit is not allowed now (a recording in progress, tracks instead of speakers).
        case refused
    }

    /// The text without invisible characters, trimmed.
    static func visible(_ text: String) -> String {
        MarkdownText.cleaned(text, keepNewlines: false).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sets the title; a blank one clears it. The notes stay current (the title is not part of them).
    static func renameTitle(_ id: Int64, to title: String, in store: MeetingsStore) throws {
        try store.renameMeeting(id, title: visible(title))
    }

    /// Renames a speaker of the meeting; the notes become `stale`. A blank name or the same name changes nothing.
    static func renameSpeaker(_ speakerID: Int64, of meetingID: Int64, to name: String, in store: MeetingsStore)
        throws
    {
        guard let speaker = try store.speakers(meetingID: meetingID).first(where: { $0.id == speakerID }) else {
            throw Failure.notFound
        }
        let trimmed = visible(name)
        guard !trimmed.isEmpty, trimmed != speaker.label else { return }
        try store.renameSpeaker(speakerID, label: trimmed)
    }

    /// Marks the speaker as the user and sets the notes `stale`. Refused for a meeting that is being recorded
    /// or has tracks instead of speakers; a speaker that is already the user changes nothing.
    static func markSelf(_ speakerID: Int64, of meetingID: Int64, in store: MeetingsStore) throws {
        guard let speaker = try store.speakers(meetingID: meetingID).first(where: { $0.id == speakerID }) else {
            throw Failure.notFound
        }
        guard !speaker.isSelf else { return }
        guard try store.speakerMode(of: meetingID) != .channels,
            try store.recoverableMeeting(id: meetingID)?.status != .recording
        else { throw Failure.refused }
        guard try store.markSelf(speakerID: speakerID) else { throw Failure.refused }
    }
}
