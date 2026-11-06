import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

private func tab(_ id: String, title: String = "T", busy: Bool = false) -> NoteTab {
    NoteTab(id: .live(Fixtures.key("meetings", id)), kind: .meeting, title: title, isBusy: busy)
}

@Suite("Notes tabs")
struct NoteTabSetTests {
    @Test("a note has one tab: opening it again selects it and refreshes its title")
    func oneTabPerNote() {
        var tabs = NoteTabSet()
        let first = tabs.open(tab("a"))
        let second = tabs.open(tab("b"))
        let again = tabs.open(tab("a", title: "Renamed"))
        #expect(first && second && !again)
        #expect(tabs.tabs.map(\.title) == ["Renamed", "T"])
        #expect(tabs.current == .live(Fixtures.key("meetings", "a")))
    }

    @Test("a detached overlay and the live note of the same key are different tabs")
    func detachedIsAnotherTab() {
        var tabs = NoteTabSet()
        let key = Fixtures.key("meetings", "a")
        tabs.open(NoteTab(id: .live(key), kind: .meeting, title: "Live"))
        tabs.open(NoteTab(id: .detached(key, startedAtMs: 5), kind: .meeting, title: "Old"))
        #expect(tabs.tabs.count == 2)
    }

    @Test("closing the current tab shows the right neighbour, else the left; closing another keeps the current")
    func closing() {
        var tabs = NoteTabSet()
        for id in ["a", "b", "c"] { tabs.open(tab(id)) }
        tabs.select(.live(Fixtures.key("meetings", "b")))
        tabs.close(.live(Fixtures.key("meetings", "a")))
        #expect(tabs.current == .live(Fixtures.key("meetings", "b")))
        tabs.close(.live(Fixtures.key("meetings", "b")))
        #expect(tabs.current == .live(Fixtures.key("meetings", "c")))
        tabs.close(.live(Fixtures.key("meetings", "c")))
        #expect(tabs.current == nil)
        #expect(tabs.tabs.isEmpty)
    }

    @Test("selecting an unknown tab changes nothing")
    func unknownSelect() {
        var tabs = NoteTabSet()
        tabs.open(tab("a"))
        tabs.select(.live(Fixtures.key("meetings", "zzz")))
        #expect(tabs.current == .live(Fixtures.key("meetings", "a")))
    }
}

@Suite("Notes explorer row text")
struct NoteRowPresentationTests {
    private let presentation: NoteRowPresentation = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return NoteRowPresentation(calendar: calendar, locale: Locale(identifier: "en_US"))
    }()
    /// The short time uses a narrow no-break space before "PM" in newer locale data.
    private func plain(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
    // 2027-01-15 14:05 UTC.
    private let start = Date(timeIntervalSince1970: 1_800_021_900)

    @Test("the title is the note's, or a name made of its kind and start")
    func titles() {
        let key = Fixtures.key("meetings", "a")
        #expect(presentation.title(NoteSummary(id: key, kind: .meeting, title: "  Plan  ", startedAt: start)) == "Plan")
        #expect(
            presentation.title(NoteSummary(id: key, kind: .meeting, title: nil, startedAt: start)).hasPrefix("Meeting"))
        #expect(
            presentation.title(NoteSummary(id: key, kind: .dictation, title: "", startedAt: start)).hasPrefix(
                "Dictation"))
        #expect(
            presentation.title(NoteSummary(id: key, kind: .manual, title: nil, startedAt: start)) == "Untitled note")
    }

    @Test("the second line is time, length and app; the date joins outside today and yesterday")
    func subtitles() {
        let key = Fixtures.key("meetings", "a")
        let meeting = NoteSummary(
            id: key, kind: .meeting, startedAt: start, durationMs: 2_520_000, sourceApp: "Zoom")
        #expect(plain(presentation.subtitle(meeting, showsDate: false)) == "2:05 PM · 42 min · Zoom")
        #expect(presentation.subtitle(meeting, showsDate: true).hasPrefix("Jan 15"))
        let dictation = NoteSummary(id: key, kind: .dictation, startedAt: start, durationMs: 18_000)
        #expect(plain(presentation.subtitle(dictation, showsDate: false)) == "2:05 PM · 0:18")
        let bare = NoteSummary(id: key, kind: .manual, startedAt: start)
        #expect(plain(presentation.subtitle(bare, showsDate: false)) == "2:05 PM")
    }

    @Test("every badge has a level, and every state except ready has words")
    func states() {
        #expect(NoteRowPresentation.level(nil) == .quiet)
        #expect(NoteRowPresentation.stateText(nil) == nil)
        let badges: [NoteBadge] = [
            .recording, .processing, .writing(done: 2, of: 5), .partial, .stale, .interrupted, .failed, .needsModel,
            .recordingRemoved, .sourceOff("meetings"),
        ]
        for badge in badges { #expect(NoteRowPresentation.stateText(badge)?.isEmpty == false) }
        #expect(NoteRowPresentation.level(.writing(done: 1, of: 2)) == .active)
        #expect(NoteRowPresentation.level(.interrupted) == .attention)
        #expect(NoteRowPresentation.level(.failed) == .error)
        #expect(NoteRowPresentation.stateText(.writing(done: 2, of: 5)) == "Writing notes 2 of 5")
    }
}
