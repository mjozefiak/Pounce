import Foundation
import LintelKit
import Testing

@testable import MeetingsPlugin

/// The two ways Notes can finish an interrupted meeting: "Finish Transcript" (`acceptGap: false`) and "Finish
/// with a Gap" (`acceptGap: true`).
@MainActor
@Suite("MeetingNoteSource: finishing an interrupted meeting")
struct MeetingNoteFinishActionTests {
    private static let words: [Int: String] = [11: "Pierwsza wypowiedź", 12: "Druga wypowiedź"]

    /// A meeting whose system track cannot be read back, so finishing without a gap leaves it incomplete.
    private func rig() throws -> (
        rig: RecoveryRig, library: MeetingsLibrary, source: MeetingNoteSource, key: NoteKey, id: Int64
    ) {
        let rig = try RecoveryRig(texts: Self.words)
        let track = TrackScript.build([(1, 11, 3), (4, 12, 3)], tail: 1)
        let meeting = try rig.seed(.incomplete, mic: track, system: .build([(2, nil, 0)], tail: 2))
        try Data().write(to: rig.spool.file(for: meeting.uuid, track: .system))
        let library = rig.library(resumer: rig.resumerFactory(mic: track))
        library.open()
        let hub = NoteChangeHub()
        let source = MeetingNoteSource(
            library: library, board: NotesBoard(), hub: hub, regenerate: nil, openNotesModel: {},
            appName: { _ in nil }, changed: { hub.notify() })
        return (
            rig, library, source, NoteKey(pluginID: "meetings", id: SpoolStorage.name(of: meeting.uuid)), meeting.id
        )
    }

    @Test func anInterruptedMeetingOffersBothActionsInTheOrderOfThePrototype() throws {
        let parts = try rig()
        #expect(parts.source.actions(for: parts.key).map(\.id) == ["meetings.finish", "meetings.finishWithGap"])
        parts.library.close()
    }

    @Test func finishTranscriptLeavesTheGapAloneAndFinishWithAGapClosesTheMeeting() async throws {
        let parts = try rig()
        let store = try #require(parts.library.store)
        let finish = try #require(parts.source.actions(for: parts.key).first { $0.id == "meetings.finish" })
        try await finish.perform()
        #expect(try store.status(of: parts.id) == .incomplete)
        #expect(try store.hasAudioGap(parts.id) == false)

        let gap = try #require(parts.source.actions(for: parts.key).first { $0.id == "meetings.finishWithGap" })
        try await gap.perform()
        #expect(try store.status(of: parts.id) == .ready)
        #expect(try store.hasAudioGap(parts.id))
        // A ready meeting has nothing left to finish.
        #expect(parts.source.actions(for: parts.key).contains { $0.id.hasPrefix("meetings.finish") } == false)
        parts.library.close()
    }
}
