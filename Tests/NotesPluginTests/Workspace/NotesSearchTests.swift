import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()

@MainActor
@Suite("Notes search across sources")
struct NotesSearchTests {
    private func rig() -> (NotesWorkspaceModel, ScriptedNoteSource, ScriptedNoteSource) {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: [
                Fixtures.summary("meetings", "a", secondsAgo: 10, title: "Pricing sync"),
                Fixtures.summary("meetings", "b", secondsAgo: 30, title: "Standup"),
                Fixtures.summary("meetings", "c", secondsAgo: 50, title: "Pricing tiers"),
            ])
        let dictation = ScriptedNoteSource(
            "dictation",
            items: [
                Fixtures.summary(
                    "dictation", "x", secondsAgo: 20, title: "Remind Marek about the pricing copy", kind: .dictation),
                Fixtures.summary("dictation", "y", secondsAgo: 40, title: "Buy milk", kind: .dictation),
            ])
        let box = SourceBox([meetings, dictation])
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: box), pasteboard: RecordingPasteboard(), saver: ScriptedSaver(),
                now: { Fixtures.epoch }, calendar: utc, locale: Locale(identifier: "en_US"), pageSize: 2))
        return (model, meetings, dictation)
    }

    @Test("a query goes to every source and the hits merge newest first, flat, without groups")
    func merge() async {
        let (model, _, _) = rig()
        await model.refresh()
        #expect(model.rows.count == 2)
        model.searchText = "  Pricing "
        await model.runSearch()
        #expect(model.isSearching)
        #expect(model.searchQuery?.normalized == "pricing")
        #expect(model.rows.map(\.id.key.rawValue) == ["meetings:a", "dictation:x"])
        #expect(model.groups.isEmpty)
        #expect(model.total == 3)
    }

    @Test("results page by the library's cursor across sources and never repeat a note")
    func paging() async {
        let (model, _, _) = rig()
        model.searchText = "pricing"
        await model.runSearch()
        #expect(model.hasMore)
        await model.loadMore()
        #expect(model.rows.map(\.id.key.rawValue) == ["meetings:a", "dictation:x", "meetings:c"])
        #expect(!model.hasMore)
        await model.loadMore()
        #expect(model.rows.count == 3)
    }

    @Test("accents and case do not matter, a blank field is the browse list, an unchanged text lists nothing again")
    func normalising() async {
        let (model, meetings, _) = rig()
        model.searchText = "PRICING"
        await model.runSearch()
        #expect(model.searchQuery?.normalized == "pricing")
        let calls = meetings.listCalls
        await model.runSearch()
        #expect(meetings.listCalls == calls)
        model.searchText = "   "
        await model.runSearch()
        #expect(!model.isSearching)
        #expect(model.groups.isEmpty == false)
    }

    @Test("a source that does not answer costs only its own hits")
    func oneSourceDown() async {
        let (model, meetings, _) = rig()
        meetings.behavior = .throwsError
        model.searchText = "pricing"
        await model.runSearch()
        #expect(model.rows.map(\.id.key.rawValue) == ["dictation:x"])
        #expect(model.unavailable.map(\.pluginID) == ["meetings"])
    }

    @Test("a hit shows the snippet of the first matched layer, only while searching")
    func snippets() async {
        let (model, meetings, _) = rig()
        meetings.items = [
            NoteSummary(
                id: Fixtures.key("meetings", "a"), kind: .meeting, title: "Sync", startedAt: Fixtures.epoch,
                matches: [NoteLayerMatch(layerID: "transcript", snippet: "…move the pricing page…")])
        ]
        await model.refresh()
        let row = model.rows[0]
        #expect(model.snippetText(of: row) == nil)
        model.searchText = "sync"
        await model.runSearch()
        #expect(model.snippetText(of: model.rows[0]) == "…move the pricing page…")
        // Hide content: the row's title is masked and its snippet (the note's own text) is not drawn at all.
        model.hidesContent = true
        #expect(model.snippetText(of: model.rows[0]) == nil)
        #expect(model.shownTitle(of: model.rows[0]) == NotesWorkspaceModel.maskedTitle)
        model.hidesContent = false
        #expect(model.shownTitle(of: model.rows[0]) == "Sync")
    }

    @Test("the highlight marks every word of the query, ignoring case and accents, and merges touching marks")
    func highlight() {
        let text = "Plany cennika: Pricing tiers, pricing"
        let ranges = NoteRowPresentation.highlightRanges(in: text, query: "PRICING plan")
        #expect(ranges.map { String(text[$0]) } == ["Plan", "Pricing", "pricing"])
        let accent = "Café and cafe"
        #expect(NoteRowPresentation.highlightRanges(in: accent, query: "cafe").count == 2)
        #expect(NoteRowPresentation.highlightRanges(in: "abc", query: "").isEmpty)
        let touching = "abab"
        #expect(NoteRowPresentation.highlightRanges(in: touching, query: "ab ba").count == 1)
    }

    @Test("a hit's label for VoiceOver reads the snippet instead of the time")
    func label() {
        let presentation = NoteRowPresentation(calendar: utc, locale: Locale(identifier: "en_US"))
        let row = NoteRow(
            id: .live(Fixtures.key("meetings", "a")),
            summary: Fixtures.summary("meetings", "a", secondsAgo: 0, title: "Sync"),
            badge: nil, overlays: [], isReadOnly: false)
        #expect(presentation.accessibilityLabel(row, showsDate: false, snippet: "…pricing…") == "Sync, …pricing…")
    }
}

@MainActor
@Suite("Notes search: no results")
struct NotesNoResultsTests {
    @Test("a search that finds nothing keeps the query for the explorer's message and clears back to the list")
    func noResults() async {
        let meetings = ScriptedNoteSource("meetings", items: [Fixtures.summary("meetings", "a", secondsAgo: 5)])
        let model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: NoteLibrary(box: SourceBox([meetings])), pasteboard: RecordingPasteboard(),
                saver: ScriptedSaver(), now: { Fixtures.epoch }, calendar: utc, locale: Locale(identifier: "en_US")))
        await model.refresh()
        model.searchText = "invoice 2019"
        await model.runSearch()
        #expect(model.isSearching)
        #expect(model.rows.isEmpty)
        #expect(model.searchQuery?.raw == "invoice 2019")
        #expect(!model.hasMore)
        await model.clearSearch()
        #expect(!model.isSearching)
        #expect(model.rows.count == 1)
    }
}

@Suite("Notes search: the library")
struct NoteLibrarySearchTests {
    @Test("a query pages across sources newest first, once each, and a source that hangs costs only its hits")
    func pagingAndBudget() async {
        let meetings = ScriptedNoteSource(
            "meetings",
            items: (0..<5).map {
                Fixtures.summary("meetings", "m\($0)", secondsAgo: Double($0 * 10 + 1), title: "Pricing \($0)")
            })
        let dictation = ScriptedNoteSource(
            "dictation",
            items: (0..<3).map {
                Fixtures.summary(
                    "dictation", "d\($0)", secondsAgo: Double($0 * 10 + 6), title: "Pricing note \($0)",
                    kind: .dictation)
            })
        let library = NoteLibrary(box: SourceBox([meetings, dictation]))
        let query = NormalizedQuery(raw: "pricing", normalized: "pricing")
        var keys: [String] = []
        var cursor: NoteListCursor?
        var pages = 0
        repeat {
            let page = await library.list(matching: query, after: cursor, limit: 3)
            keys += page.rows.map(\.id.key.rawValue)
            cursor = page.next
            pages += 1
        } while cursor != nil && pages < 10
        #expect(
            keys == [
                "meetings:m0", "dictation:d0", "meetings:m1", "dictation:d1", "meetings:m2", "dictation:d2",
                "meetings:m3", "meetings:m4",
            ])
        #expect(Set(keys).count == keys.count)

        let clock = ManualClock()
        dictation.behavior = .hangs
        let slow = NoteLibrary(
            sources: { [meetings, dictation] }, overlays: FakeOverlayStore(), detacher: FakeOverlayStore(), clock: clock
        )
        let task = Task { await slow.list(matching: query, after: nil, limit: 3) }
        await clock.waitForSleeps(2)
        // The answering source's deadline is cancelled once it answered; only the hanging one's is left to fire.
        await clock.waitForCancelledSleeps(1)
        clock.advance(by: .milliseconds(150))
        let result = await task.value
        #expect(result.rows.map(\.id.key.rawValue) == ["meetings:m0", "meetings:m1", "meetings:m2"])
        #expect(result.unavailable == [UnavailableSource(pluginID: "dictation", reason: .timedOut)])
    }
}
