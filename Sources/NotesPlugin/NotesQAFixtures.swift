#if DEBUG
import Foundation
import LintelKit

/// Fixture notes for `--qa-notes`: invented text only, shaped like the accepted prototype's sample data (one
/// finished meeting with notes and a transcript, a dictation, a meeting still writing its notes, an interrupted
/// one, a failed one; manual notes come with the store, step 4.0). They stand in for the real sources while a QA run looks at the section.
enum NotesQAFixtures {
    static let meetingID = NoteKey(pluginID: "meetings", id: "00000000-0000-0000-0000-000000000001")
    static let dictationID = NoteKey(pluginID: "dictation", id: "fixture/1")
    static let writingID = NoteKey(pluginID: "meetings", id: "00000000-0000-0000-0000-000000000004")
    static let interruptedID = NoteKey(pluginID: "meetings", id: "00000000-0000-0000-0000-000000000005")
    static let reminderID = NoteKey(pluginID: "dictation", id: "fixture/2")
    static let needsModelID = NoteKey(pluginID: "meetings", id: "00000000-0000-0000-0000-000000000007")
    static let failedID = NoteKey(pluginID: "meetings", id: "00000000-0000-0000-0000-000000000006")

    /// The notes, newest first, dated relative to `now` so a QA run always shows today and yesterday.
    static func summaries(now: Date = Date()) -> [NoteSummary] {
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [
            NoteSummary(
                id: meetingID, kind: .meeting, title: "Orchard weekly sync", startedAt: ago(3), durationMs: 2_520_000,
                sourceApp: "Zoom", state: .ready),
            NoteSummary(
                id: dictationID, kind: .dictation, title: "Hi Kasia, I moved the review to Thursday at 10.",
                startedAt: ago(4), durationMs: 18_000, sourceApp: "Mail", state: .ready),
            NoteSummary(
                id: writingID, kind: .meeting, title: nil, startedAt: ago(5.5), durationMs: 720_000,
                state: .writing(done: 2, of: 5)),
            NoteSummary(
                id: interruptedID, kind: .meeting, title: "Customer call", startedAt: ago(27), durationMs: 1_860_000,
                sourceApp: "Teams", state: .interrupted),
            NoteSummary(
                id: reminderID, kind: .dictation, title: "Reminder: renew the domain before Friday", startedAt: ago(30),
                durationMs: 7_000, state: .ready),
            NoteSummary(
                id: needsModelID, kind: .meeting, title: "Planning", startedAt: ago(52), durationMs: 1_500_000,
                sourceApp: "Zoom", state: .needsModel),
            NoteSummary(
                id: failedID, kind: .meeting, title: "Design review", startedAt: ago(96), durationMs: 3_480_000,
                sourceApp: "Meet", state: .failed),
        ]
    }

    static let meetingNotes = """
        ## Summary

        The team agreed to ship the new onboarding on 12 Nov and to postpone the pricing page. \\[12:41\\]

        ## Decisions

        - Ship onboarding on 12 Nov. \\[12:42\\]
        - Pricing page moves to the next sprint (Marek confirmed). \\[12:43\\]

        ## Tasks

        | # | Task | Owner | Due | Source |
        | --- | --- | --- | --- | --- |
        | T1 | Update the release checklist | Kasia | Thu | \\[12:44\\] |
        | T2 | Send the demo build to QA | Marek | today | \\[12:43\\] |

        ## Open questions

        - Who reviews the Polish translation? \\[12:46\\]
        """

    /// Segments: (speaker id, start ms, text).
    static let segments: [(speaker: String, start: Int, text: String)] = [
        ("1", 761_000, "I’d move the pricing page, it isn’t ready."),
        ("3", 762_000, "Agreed. Onboarding first, then pricing."),
        ("2", 763_000, "I’ll send QA the demo build today."),
        ("1", 764_000, "And I’ll update the release checklist by Thursday."),
        ("2", 766_000, "Who reviews the Polish translation?"),
    ]

    static let speakers = [
        NoteSpeaker(id: "1", name: "Kasia"), NoteSpeaker(id: "2", name: "Marek"),
        NoteSpeaker(id: "3", name: "You", isSelf: true),
    ]

    static func content(for key: NoteKey, now: Date = Date()) -> NoteContent? {
        guard let summary = summaries(now: now).first(where: { $0.id == key }) else { return nil }
        switch key {
        case meetingID:
            var provenance: [NoteBlockProvenance] = []
            // Blocks: 0 heading, 1 summary, 2 heading, 3 and 4 decisions, 5 heading, 6 table, 7 heading, 8 question.
            for (index, time) in [(1, 761_000), (3, 762_000), (4, 763_000), (8, 766_000)] {
                provenance.append(NoteBlockProvenance(blockIndex: index, quoteTimesMs: [time]))
            }
            let transcript = segments.map { $0.text }.joined(separator: "\n\n")
            let transcriptProvenance = segments.enumerated().map { index, segment in
                NoteBlockProvenance(
                    blockIndex: index, speakerID: segment.speaker, startMs: segment.start, segmentRef: "\(index)")
            }
            return NoteContent(
                summary: summary,
                layers: [
                    NoteLayer(
                        id: "notes", author: .agent, markdown: meetingNotes, provenance: provenance, version: "1"),
                    NoteLayer(
                        id: "transcript", author: .stt, markdown: transcript, provenance: transcriptProvenance,
                        version: "1"),
                ], speakers: speakers,
                details: [NoteDetail(label: "Speech model", value: "Parakeet Ultra")])
        case dictationID:
            return NoteContent(
                summary: summary,
                layers: [
                    NoteLayer(
                        id: "cleaned", author: .agent,
                        markdown:
                            "Hi Kasia, I moved the review to Thursday at 10. Could you send me the agenda beforehand?",
                        version: "1"),
                    NoteLayer(
                        id: "original", author: .stt,
                        markdown:
                            "hi kasia i moved the review to thursday at ten uh could you send me the agenda before hand",
                        version: "1"),
                ], speakers: [], details: [])
        case reminderID:
            return NoteContent(
                summary: summary,
                layers: [
                    NoteLayer(
                        id: "cleaned", author: .agent, markdown: "Reminder: renew the domain before Friday.",
                        version: "1")
                ], speakers: [], details: [])
        case needsModelID:
            return NoteContent(
                summary: summary,
                layers: [
                    NoteLayer(
                        id: "transcript", author: .stt,
                        markdown: segments.map { $0.text }.joined(separator: "\n\n"),
                        provenance: segments.enumerated().map { index, segment in
                            NoteBlockProvenance(
                                blockIndex: index, speakerID: segment.speaker, startMs: segment.start,
                                segmentRef: "\(index)")
                        }, version: "1")
                ], speakers: speakers, details: [])
        default:
            return NoteContent(summary: summary, layers: [], speakers: [], details: [])
        }
    }
}

/// A `NoteSource` over the fixtures of one plugin id (`--qa-notes`), so the section reads them the way it reads a
/// real plugin's notes.
struct NotesQAFixtureSource: NoteSource {
    let pluginID: PluginID
    var now: Date = Date()

    private var items: [NoteSummary] {
        isEmpty ? [] : NotesQAFixtures.summaries(now: now).filter { $0.id.pluginID == pluginID }
    }

    /// A query keeps the notes whose title or text holds it (case and accents ignored) and names the line of
    /// the first layer that does, the way a real source reports `matches`.
    private func matching(_ query: NormalizedQuery?) -> [NoteSummary] {
        guard let query, !query.isEmpty else { return items }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.compactMap { summary in
            var found = summary
            let layers = NotesQAFixtures.content(for: summary.id, now: now)?.layers ?? []
            for layer in layers {
                let line = layer.markdown.split(separator: "\n").first {
                    $0.range(of: query.raw, options: options) != nil
                }
                if let line {
                    found.matches.append(
                        NoteLayerMatch(layerID: layer.id, snippet: String(line.prefix(120))))
                }
            }
            let titled = summary.title?.range(of: query.raw, options: options) != nil
            return titled || !found.matches.isEmpty ? found : nil
        }
    }

    func list(matching query: NormalizedQuery?, after: NoteCursor?, limit: Int) async throws -> NotePage {
        let all = matching(query)
        let start = after.flatMap { Int($0.token) } ?? 0
        let end = min(all.count, start + limit)
        return NotePage(
            items: Array(all[min(start, end)..<end]), next: end < all.count ? NoteCursor(token: "\(end)") : nil,
            total: all.count)
    }

    func exists(_ keys: [NoteKey]) async throws -> Set<NoteKey> { Set(keys).intersection(items.map(\.id)) }
    func content(for key: NoteKey) async throws -> NoteContent? {
        key.pluginID == pluginID ? NotesQAFixtures.content(for: key, now: now) : nil
    }
    func delete(_ key: NoteKey) async throws {}
    /// The interrupted meeting offers "Finish" (it does nothing here), the way Meetings does for a spooled one.
    func actions(for key: NoteKey) -> [NoteSourceAction] {
        guard key == NotesQAFixtures.interruptedID else { return [] }
        return [
            NoteSourceAction(
                id: "fixture.finish",
                title: LocalizedStringResource("Finish", comment: "Notes: finish an interrupted transcript"),
                symbolName: "checkmark.circle"
            ) {}
        ]
    }
    func makeChanges() -> AsyncStream<Void> { AsyncStream { $0.finish() } }

    var isEmpty = false

    static func all(now: Date = Date(), empty: Bool = false) -> [any NoteSource] {
        ["meetings", "dictation"].map {
            NotesQAFixtureSource(pluginID: PluginID(rawValue: $0), now: now, isEmpty: empty)
        }
    }
}
#endif

/// An overlay index that cannot be read (`plugins.notes.qaState=locked`): the library lists the sources without
/// overlays and reports `overlaysAvailable == false`, the state of a Keychain error opening `notes.sqlite`.
struct NotesQALockedOverlays: OverlayIndex, OverlayDetacher {
    struct Locked: Error {}
    func overlays(for keys: [NoteKey]) async throws -> [OverlayRecord] { throw Locked() }
    func manualNotes() async throws -> [OverlayRecord] { throw Locked() }
    func detachedOverlays() async throws -> [OverlayRecord] { throw Locked() }
    func keptOverlays(excludingPlugins excluding: Set<PluginID>) async throws -> [OverlayRecord] { throw Locked() }
    func liveOverlayKeys() async throws -> [NoteKey] { throw Locked() }
    func detach(_ key: NoteKey, reason: OverlayDetachReason) async throws {}
}
