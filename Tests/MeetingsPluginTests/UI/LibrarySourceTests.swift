import Foundation
import LintelKit
import Testing

@testable import MeetingsPlugin

// MARK: Fakes and rig

@MainActor final class FakePanel: PanelPresenter {
    nonisolated init() {}
    private(set) var hidden = 0
    private(set) var confirmations: [String] = []
    func hidePanel() { hidden += 1 }
    func showConfirmation(_ message: LocalizedStringResource) {
        confirmations.append(String(localized: message))
    }
}

private func query(_ text: String) -> NormalizedQuery {
    NormalizedQuery(raw: text, normalized: text.lowercased())
}

private let utc = ExportFixtures.utc
private let english = Locale(identifier: "en_US")

/// A harness with an open library holding five meetings (newest first: ready with notes, stale notes, ready
/// without notes, incomplete, failed).
@MainActor
struct LibraryRig {
    let harness: MeetingsHarness
    let library: MeetingsLibrary
    let pasteboard = RecordingPasteboard()
    let panel = FakePanel()
    let actions: MeetingsLibraryActions
    let source: MeetingsLibrarySource
    let ids: [String: Int64]

    var store: MeetingsStore {
        get throws { try #require(library.store) }
    }

    init(regenerate: (@MainActor (Int64) -> Void)? = nil) throws {
        harness = try MeetingsHarness()
        library = harness.library()
        library.open()
        let store = try #require(library.store)
        let pasteboard = pasteboard
        actions = MeetingsLibraryActions(
            library: library, pasteboard: pasteboard, labels: .english, timeZone: utc, regenerate: regenerate)
        let library = library
        source = MeetingsLibrarySource(
            store: { library.store }, actions: actions, timeZone: utc, locale: english,
            appName: { $0 == "us.zoom.xos" ? "Zoom" : nil })

        let base = ExportFixtures.started
        func add(
            _ key: String, daysAgo: Double, title: String?, status: MeetingStatus, notes: String?,
            notesStatus: NotesStatus, duration: Int, bundle: String?, text: String?
        ) throws -> (String, Int64) {
            let id = try store.insertMeeting(
                uuid: UUID().uuidString.lowercased(), startedAt: base.addingTimeInterval(-daysAgo * 86_400),
                speechModelID: "m", status: status, sourceBundleID: bundle)
            try store.write { db in
                try db.execute(
                    sql: "UPDATE meeting SET duration_ms = ?, speaker_mode = 'diarized' WHERE id = ?",
                    arguments: [duration, id])
            }
            if let title { try store.setTitle(id, title: title) }
            if let notes { try store.setNotes(id, markdown: notes, status: notesStatus) }
            let speaker = try store.insertSpeaker(meetingID: id, label: "Anna", isSelf: false, channel: .system)
            if let text {
                try store.insertSegment(
                    meetingID: id, channel: .system, startMs: 1000, endMs: 2000, text: text, speakerID: speaker)
            }
            return (key, id)
        }
        let rows = [
            try add(
                "notes", daysAgo: 0, title: "Planning budżetu", status: .ready,
                notes: "## Decyzje\n\n- Budżet zatwierdzony", notesStatus: .ok, duration: 3_900_000,
                bundle: "us.zoom.xos", text: "Dzień dobry wszystkim"),
            try add(
                "stale", daysAgo: 1, title: "Retro", status: .ready, notes: "Stare notatki", notesStatus: .stale,
                duration: 600_000, bundle: nil, text: "Retrospektywa"),
            try add(
                "plain", daysAgo: 2, title: nil, status: .ready, notes: nil, notesStatus: .none, duration: 45_000,
                bundle: "com.example.gone", text: "Roadmapa kwartału łączy"),
            try add(
                "incomplete", daysAgo: 3, title: "Przerwane", status: .incomplete, notes: nil, notesStatus: .none,
                duration: 120_000, bundle: nil, text: nil),
            try add(
                "failed", daysAgo: 4, title: "Awaria", status: .failed, notes: nil, notesStatus: .none, duration: 0,
                bundle: nil, text: nil),
        ]
        ids = Dictionary(uniqueKeysWithValues: rows)
    }

    func search(_ text: String = "", filter: MeetingLibraryFilter? = nil, limit: Int = 100) async throws
        -> [Candidate]
    {
        try await source.search(query(text), filter: filter?.rawValue, limit: limit)
    }

    func keys(_ candidates: [Candidate]) -> [String] {
        candidates.compactMap { candidate in
            MeetingLibraryPresentation.meetingID(candidate.itemKey).flatMap { id in
                ids.first { $0.value == id }?.key
            }
        }
    }
}

// MARK: Rows, filters, search

@MainActor
@Suite struct MeetingsLibrarySourceTests {
    @Test func rowsAreNewestFirstWithTitleDateDurationAppAndBadge() async throws {
        let rig = try LibraryRig()
        let rows = try await rig.search()
        #expect(rig.keys(rows) == ["notes", "stale", "plain", "incomplete", "failed"])

        let first = rows[0]
        #expect(first.title == "Planning budżetu")
        let subtitle = try #require(first.subtitle)
        #expect(subtitle.contains("Nov 3, 2026"))
        #expect(subtitle.contains("1 hr, 5 min"))
        #expect(subtitle.hasSuffix("Zoom"))
        #expect(first.badge == "Notes")
        #expect(first.icon == .symbol("doc.text"))
        #expect(first.itemKey.pluginID == "meetings")

        // No title: the date; an app that is not installed adds nothing; under a minute shows seconds.
        let plain = rows[2]
        #expect(plain.title.hasPrefix("Meeting "))
        #expect(plain.badge == nil)
        let plainSubtitle = try #require(plain.subtitle)
        #expect(plainSubtitle.contains("Nov 1, 2026"))
        #expect(plainSubtitle.contains("45 sec"))
        #expect(!plainSubtitle.contains("gone"))

        // A meeting that recorded nothing has no duration.
        #expect(rows[4].subtitle?.contains("sec") == false)
        #expect(rows[4].subtitle?.contains("min") == false)
    }

    @Test func badgesFollowTheMeetingThenTheNotes() async throws {
        let rig = try LibraryRig()
        let rows = try await rig.search()
        #expect(rows.map(\.badge) == ["Notes", "Notes outdated", nil, "Incomplete", "Failed"])
        func entry(_ status: MeetingStatus, _ notes: NotesStatus) -> MeetingLibraryEntry {
            .init(
                id: 1, startedAt: Date(), durationMs: 0, title: nil, sourceBundleID: nil, status: status,
                notesStatus: notes, hasNotes: notes != .none)
        }
        #expect(MeetingLibraryPresentation.badge(entry(.recording, .none)) == "Recording")
        #expect(MeetingLibraryPresentation.badge(entry(.processing, .none)) == "Processing")
        #expect(MeetingLibraryPresentation.badge(entry(.ready, .partial)) == "Partial notes")
        #expect(MeetingLibraryPresentation.badge(entry(.ready, .failed)) == "Notes failed")
        #expect(MeetingLibraryPresentation.badge(entry(.ready, .running)) == "Writing notes")
    }

    @Test func aTitleOfInvisibleCharactersFallsBackToTheDate() {
        let entry = MeetingLibraryEntry(
            id: 1, startedAt: ExportFixtures.started, durationMs: 0, title: "\u{200B}\u{202E} ", sourceBundleID: nil,
            status: .ready, notesStatus: .none, hasNotes: false)
        #expect(MeetingLibraryPresentation.title(entry, timeZone: utc).hasPrefix("Meeting "))
        let bidi = MeetingLibraryEntry(
            id: 1, startedAt: ExportFixtures.started, durationMs: 0, title: "Sync\u{202E}gnp.exe", sourceBundleID: nil,
            status: .ready, notesStatus: .none, hasNotes: false)
        #expect(MeetingLibraryPresentation.title(bidi, timeZone: utc) == "Syncgnp.exe")
    }

    @Test func theFiltersNarrowTheList() async throws {
        let rig = try LibraryRig()
        #expect(rig.keys(try await rig.search(filter: .all)).count == 5)
        #expect(rig.keys(try await rig.search(filter: .withNotes)) == ["notes", "stale"])
        #expect(rig.keys(try await rig.search(filter: .needsAttention)) == ["stale", "incomplete", "failed"])
        // An unknown filter id behaves like All.
        let unknown = try await rig.source.search(query(""), filter: "nope", limit: 10)
        #expect(unknown.count == 5)
        // A filter and a query work together.
        #expect(rig.keys(try await rig.search("retro", filter: .needsAttention)) == ["stale"])
        #expect(try await rig.search("retro", filter: .withNotes).count == 1)
        #expect(try await rig.search("roadmapa", filter: .withNotes).isEmpty)
    }

    @Test func aQuerySearchesTitlesNotesAndTheTranscriptWithPolishFolding() async throws {
        let rig = try LibraryRig()
        // Title (notes index), diacritics folded.
        #expect(rig.keys(try await rig.search("budzetu")) == ["notes"])
        #expect(rig.keys(try await rig.search("PLANN")) == ["notes"])
        // Notes text.
        #expect(rig.keys(try await rig.search("zatwierdz")) == ["notes"])
        // Transcript text, ł folded by hand.
        #expect(rig.keys(try await rig.search("laczy")) == ["plain"])
        #expect(rig.keys(try await rig.search("dzien dob")) == ["notes"])
        // Nothing, and a query without any searchable word.
        #expect(try await rig.search("nieistnieje").isEmpty)
        #expect(try await rig.search("***").isEmpty)
        #expect(try await rig.search("\"").isEmpty)
    }

    @Test func aQueryThatLooksLikeFTSSyntaxIsJustText() async throws {
        let rig = try LibraryRig()
        #expect(try await rig.search("a OR b NOT").isEmpty)
        #expect(try await rig.search("title:Retro").isEmpty)
        #expect(try await rig.search("Retro AND").isEmpty)
    }

    @Test func theListIsCappedByTheLimitAndByTheMaximum() async throws {
        let rig = try LibraryRig()
        #expect(try await rig.search(limit: 2).count == 2)
        #expect(try await rig.search(limit: 0).isEmpty)
        let store = try rig.store
        try store.write { db in
            for index in 0..<1100 {
                try db.execute(
                    sql: "INSERT INTO meeting (uuid, started_at, speech_model_id, status) VALUES (?, ?, 'm', 'ready')",
                    arguments: ["bulk-\(index)", Double(index)])
            }
        }
        #expect(try await rig.search(limit: 5000).count == MeetingsLibrarySource.maxRows)
        // Newest first: the five rig meetings (2026) come before the bulk ones (1970).
        #expect(rig.keys(Array(try await rig.search(limit: 5000).prefix(5))).count == 5)
    }

    @Test func anEmptyLibraryGivesNoRows() async throws {
        let harness = try MeetingsHarness()
        let library = harness.library()
        library.open()
        let actions = MeetingsLibraryActions(library: library, pasteboard: RecordingPasteboard())
        let source = MeetingsLibrarySource(store: { library.store }, actions: actions)
        #expect(try await source.search(query(""), filter: nil, limit: 10).isEmpty)
        #expect(try await source.search(query("x"), filter: "withNotes", limit: 10).isEmpty)
        #expect(MeetingLibraryMessages.unavailable(library.status) == nil)
        #expect(MeetingLibraryMessages.empty.contains("No meetings yet"))
    }

    @Test func anUnavailableLibraryGivesNoRowsAndAnExplanation() async throws {
        let harness = try MeetingsHarness()
        harness.keychain.failReads(with: .interactionNotAllowed)
        let library = harness.library()
        library.open()
        guard case .unavailable = library.status else {
            Issue.record("expected an unavailable library")
            return
        }
        let actions = MeetingsLibraryActions(library: library, pasteboard: RecordingPasteboard())
        let source = MeetingsLibrarySource(store: { library.store }, actions: actions)
        #expect(try await source.search(query(""), filter: nil, limit: 10).isEmpty)
        #expect(MeetingLibraryMessages.unavailable(library.status)?.contains("Keychain") == true)
        #expect(MeetingLibraryMessages.unavailable(.failed)?.contains("could not be opened") == true)
        #expect(MeetingLibraryMessages.unavailable(.ready) == nil)
        await #expect(throws: MeetingLibraryActionError.unavailable) { try await actions.copyMarkdown(1) }
        await #expect(throws: MeetingLibraryActionError.unavailable) { try await actions.delete(1) }
        // Nothing was written to the Keychain or the disk.
        #expect(harness.keychain.itemNames.isEmpty)
    }

    @Test func aCancelledSearchThrows() async throws {
        let rig = try LibraryRig()
        let task = Task { () -> [Candidate] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await rig.source.search(query(""), filter: nil, limit: 10)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func theSourceNeverTouchesTheRankingDatabase() async throws {
        let rig = try LibraryRig()
        let rows = try await rig.search("budzet")
        for action in rig.source.actions(for: try #require(rows.first)) where action.id != "meetings.library.delete" {
            if action.id == "meetings.library.copy" {
                try await action.perform(
                    ActionContext(previousApp: nil, panel: rig.panel))
            }
        }
        #expect(rig.harness.usage.callCount == 0)
    }
}

// MARK: Actions

@MainActor
@Suite struct MeetingsLibraryActionTests {
    private func context(_ rig: LibraryRig) -> ActionContext {
        ActionContext(previousApp: nil, panel: rig.panel)
    }

    @Test func theActionsAreCopyOpenAndDeleteWithTheContractedShortcuts() async throws {
        let rig = try LibraryRig()
        let row = try #require(try await rig.search().first)
        let actions = rig.source.actions(for: row)
        #expect(actions.map(\.id) == ["meetings.library.copy", "meetings.library.open", "meetings.library.delete"])
        #expect(actions[0].shortcut == nil)
        #expect(actions[1].shortcut == KeyShortcut(key: "o", modifiers: .command))
        #expect(actions[2].shortcut == KeyShortcut(key: "x", modifiers: .control))
        #expect(actions[2].keepsPanelOpen)
        #expect(!actions[0].keepsPanelOpen)
        #expect(
            rig.source.actions(
                for: Candidate(
                    itemKey: ItemKey(pluginID: "apps", key: "x"), title: "", icon: .symbol("a"),
                    match: MatchResult(tier: .exact, score: 0))
            ).isEmpty)
    }

    @Test func regenerateIsOfferedOnlyWithANotesPipeline() async throws {
        let calls = Box<[Int64]>([])
        let rig = try LibraryRig(regenerate: { id in calls.withLock { $0.append(id) } })
        let row = try #require(try await rig.search().first)
        let actions = rig.source.actions(for: row)
        #expect(
            actions.map(\.id) == [
                "meetings.library.copy", "meetings.library.open", "meetings.library.regenerate",
                "meetings.library.delete",
            ])
        let regenerate = try #require(actions.first { $0.id == "meetings.library.regenerate" })
        #expect(regenerate.shortcut == KeyShortcut(key: "r", modifiers: .command))
        try await regenerate.perform(context(rig))
        #expect(calls.withLock { $0 } == [try #require(rig.ids["notes"])])
    }

    @Test func returnCopiesTheMarkdownMarkedTransientAndConcealed() async throws {
        let rig = try LibraryRig()
        let row = try #require(try await rig.search().first)
        let copy = try #require(rig.source.actions(for: row).first)
        try await copy.perform(context(rig))

        let item = try #require(rig.pasteboard.written.first?.first)
        let text = try #require(
            item.data(for: PasteboardRepresentation.plainTextType).flatMap { String(data: $0, encoding: .utf8) })
        #expect(text.hasPrefix("# Planning budżetu"))
        #expect(text.contains("Budżet zatwierdzony"))
        #expect(text.contains("Dzień dobry wszystkim"))
        #expect(item.types.contains(PasteboardRepresentation.transientMarkerType))
        #expect(item.types.contains(PasteboardRepresentation.concealedMarkerType))
        #expect(rig.pasteboard.written.count == 1)
        #expect(rig.panel.confirmations == ["Copied Markdown"])
    }

    @Test func aMeetingWithoutAnyTextIsNotCopied() async throws {
        let rig = try LibraryRig()
        let incomplete = try #require(rig.ids["incomplete"])
        await #expect(throws: MeetingLibraryActionError.nothingToCopy) {
            try await rig.actions.copyMarkdown(incomplete)
        }
        await #expect(throws: MeetingLibraryActionError.missing) { try await rig.actions.copyMarkdown(9999) }
        #expect(rig.pasteboard.written.isEmpty)
    }

    @Test func deleteRemovesTheMeetingItsRowsAndItsSpool() async throws {
        let rig = try LibraryRig()
        let store = try rig.store
        let uuid = UUID()
        let spoolDirectory = try rig.library.spoolStorage.prepare(meeting: uuid)
        let id = try store.insertMeeting(
            uuid: SpoolStorage.name(of: uuid), startedAt: Date(), speechModelID: "m", status: .incomplete)
        _ = try store.insertSpeaker(meetingID: id, label: "Ja", isSelf: true, channel: .mic)
        #expect(FileManager.default.fileExists(atPath: spoolDirectory.path))

        let row = try #require(try await rig.search().first { $0.itemKey == MeetingLibraryPresentation.itemKey(id) })
        let delete = try #require(rig.source.actions(for: row).last)
        // The shell asks first (`confirmation`, step 6.2) and runs the action on the second ⌃X; the action
        // itself deletes at once.
        #expect(delete.confirmation != nil)
        try await delete.perform(context(rig))

        #expect(try store.loadDocument(id: id) == nil)
        #expect(try store.speakerCount(meetingID: id) == 0)
        #expect(!FileManager.default.fileExists(atPath: spoolDirectory.path))
        #expect(try await rig.search().count == 5)
        #expect(rig.library.meetingCount == 5)
        // Deleting again says the meeting is gone.
        await #expect(throws: MeetingLibraryActionError.missing) { try await rig.actions.delete(id) }
    }

    @Test func aMeetingBeingRecordedIsNotDeleted() async throws {
        let rig = try LibraryRig()
        let store = try rig.store
        let id = try store.insertMeeting(uuid: UUID().uuidString.lowercased(), startedAt: Date(), speechModelID: "m")
        await #expect(throws: MeetingActionError.active) { try await rig.actions.delete(id) }
        #expect(try store.status(of: id) == .recording)
    }

    @Test func nothingIsRecordedInTheRankingDatabase() async throws {
        let rig = try LibraryRig()
        let rows = try await rig.search("budzet")
        let first = try #require(rows.first)
        for action in rig.source.actions(for: first) where action.id == "meetings.library.copy" {
            try await action.perform(context(rig))
        }
        let plain = try #require(try await rig.search("roadmapa").first)
        try await #require(rig.source.actions(for: plain).last).perform(context(rig))
        #expect(rig.harness.usage.callCount == 0)
    }
}

// MARK: Preview

@Suite struct MeetingPreviewTests {
    private func document(
        notes: String? = nil, notesStatus: NotesStatus = .none, status: MeetingStatus = .ready,
        segments: [MeetingDocument.Segment] = []
    ) -> MeetingDocument {
        MeetingDocument(
            id: 1, uuid: "u", startedAt: ExportFixtures.started, durationMs: 90_000, title: "T", status: status,
            speakerMode: .diarized, audioState: .deleted, notesMarkdown: notes, notesStatus: notesStatus,
            notesDroppedCount: 0,
            speakers: [.init(id: 1, label: "Anna", isSelf: false, channel: .system)], segments: segments)
    }

    private func segment(_ id: Int64, _ ms: Int, _ text: String, speaker: Int64? = 1) -> MeetingDocument.Segment {
        .init(id: id, channel: .system, startMs: ms, endMs: ms + 500, speakerID: speaker, text: text)
    }

    private func build(_ document: MeetingDocument) -> MeetingPreviewContent {
        MeetingPreviewBuilder.build(document, labels: .english, locale: english, timeZone: utc)
    }

    @Test func notesComeFirstAndTheTranscriptIsTheFallback() {
        let withNotes = build(
            document(notes: "## Decisions\n- Ship", notesStatus: .ok, segments: [segment(1, 0, "Hi")]))
        #expect(withNotes.kind == .notes)
        #expect(withNotes.text == "## Decisions\n- Ship")
        #expect(withNotes.notice == nil)
        #expect(withNotes.metadata.contains("1 min"))

        let transcript = build(
            document(segments: [
                segment(2, 5000, "Second"), segment(1, 1000, "First"), segment(3, 6000, "Who", speaker: nil),
            ]))
        #expect(transcript.kind == .transcript)
        #expect(
            transcript.text == "[00:00:01] Anna: First\n[00:00:05] Anna: Second\n[00:00:06] Unknown speaker: Who")
    }

    @Test func staleNotesCarryANoticeAndBlankNotesFallBackToTheTranscript() {
        let stale = build(document(notes: "Old", notesStatus: .stale))
        #expect(stale.kind == .notes)
        #expect(stale.notice == MarkdownExporter.Labels.english.staleNotes)
        let blank = build(document(notes: " \n ", notesStatus: .ok, segments: [segment(1, 0, "Hi")]))
        #expect(blank.kind == .transcript)
    }

    @Test func aMeetingWithoutTextShowsAPlaceholderForItsState() {
        for status in MeetingStatus.allCases {
            let content = build(document(status: status))
            #expect(content.kind == .placeholder)
            #expect(!content.text.isEmpty)
        }
        #expect(build(document(status: .recording)).text.contains("recorded"))
        #expect(build(document(status: .processing)).text.contains("prepared"))
    }

    @Test func hostileTextStaysPlainTextWithoutInvisibleControls() {
        let hostile = "![x](http://evil.example/p.png)\n[link](javascript:alert(1)) <img src=x> \u{202E}evil\u{200B}"
        let notes = build(document(notes: hostile, notesStatus: .ok))
        #expect(notes.text.contains("![x](http://evil.example/p.png)"))
        #expect(notes.text.contains("evil"))
        #expect(!notes.text.contains("\u{202E}"))
        #expect(!notes.text.contains("\u{200B}"))
        let transcript = build(
            document(segments: [segment(1, 0, "Say ![x](http://evil.example/a.png)\u{0007} now\u{2067}")]))
        #expect(transcript.text == "[00:00:00] Anna: Say ![x](http://evil.example/a.png)  now")
        #expect(!transcript.text.contains("\u{0007}"))
        #expect(!transcript.text.contains("\u{2067}"))
    }

    @Test func aVeryLongTranscriptIsCut() {
        let segments = (0..<5000).map { segment(Int64($0), $0 * 1000, String(repeating: "word ", count: 20)) }
        let content = build(document(segments: segments))
        #expect(content.isTruncated)
        #expect(content.text.count == MeetingPreviewBuilder.maxCharacters)
        let long = build(document(notes: String(repeating: "x", count: 50_000), notesStatus: .ok))
        #expect(long.isTruncated)
        #expect(long.text.count == MeetingPreviewBuilder.maxCharacters)
        #expect(!build(document(notes: "short", notesStatus: .ok)).isTruncated)
    }
}

@Suite struct MeetingLibraryStoreTests {
    @Test func theFilterClausesAreExactlyTheContractedOnes() {
        #expect(MeetingLibraryFilter.all.clause == nil)
        #expect(MeetingLibraryFilter.allCases.map(\.rawValue) == ["all", "withNotes", "needsAttention"])
        #expect(MeetingLibraryFilter.needsAttention.clause?.contains("'incomplete', 'failed'") == true)
        #expect(MeetingLibraryFilter.needsAttention.clause?.contains("'failed', 'stale'") == true)
    }

    @Test func presentationDurationsUseWholeMinutes() {
        #expect(MeetingLibraryPresentation.duration(milliseconds: 0, locale: english) == nil)
        #expect(MeetingLibraryPresentation.duration(milliseconds: 999, locale: english) == nil)
        #expect(MeetingLibraryPresentation.duration(milliseconds: 59_999, locale: english) == "59 sec")
        #expect(MeetingLibraryPresentation.duration(milliseconds: 60_000, locale: english) == "1 min")
        #expect(MeetingLibraryPresentation.duration(milliseconds: 3_599_000, locale: english) == "59 min")
        #expect(MeetingLibraryPresentation.duration(milliseconds: 10_800_000, locale: english) == "3 hr")
    }

    @Test func itemKeysRoundTripAndOtherPluginsAreIgnored() {
        let key = MeetingLibraryPresentation.itemKey(42)
        #expect(key.key == "meeting:42")
        #expect(MeetingLibraryPresentation.meetingID(key) == 42)
        #expect(MeetingLibraryPresentation.meetingID(ItemKey(pluginID: "dictation", key: "meeting:42")) == nil)
        #expect(MeetingLibraryPresentation.meetingID(ItemKey(pluginID: "meetings", key: "meeting:x")) == nil)
    }
}
