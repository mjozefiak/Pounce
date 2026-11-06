#if DEBUG
import Foundation
import LintelKit

/// Fixture notes for `--qa-notes`: invented text only, one per kind. There is no store yet (step 4.0), so these
/// are the only notes the section can show.
enum NotesQAFixtures {
    static let summaries: [NoteSummary] = [
        NoteSummary(
            id: NoteKey(pluginID: "meetings", id: "00000000-0000-0000-0000-000000000001"), kind: .meeting,
            title: "Fixture: weekly sync", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMs: 1_800_000, state: .ready),
        NoteSummary(
            id: NoteKey(pluginID: "dictation", id: "fixture/1"), kind: .dictation,
            title: "Fixture: dictated reminder", startedAt: Date(timeIntervalSince1970: 1_700_100_000),
            durationMs: 12_000, state: .ready),
        NoteSummary(
            id: NoteKey(pluginID: "notes", id: "00000000-0000-0000-0000-000000000003"), kind: .manual,
            title: "Fixture: a manual note", startedAt: Date(timeIntervalSince1970: 1_700_200_000), state: .ready),
    ]
}
#endif
