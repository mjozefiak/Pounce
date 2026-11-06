import Foundation
import LintelKit
import Testing

@testable import NotesPlugin

/// A fixed calendar and locale so row text does not depend on the machine.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}()
private let english = Locale(identifier: "en_US")

@MainActor
private struct Rig {
    let meetings: ScriptedNoteSource
    let dictation: ScriptedNoteSource
    let model: NotesWorkspaceModel
    let sourceSet: AsyncStream<Void>.Continuation
    let settingsOpened = Counter()
    let pasteboard = RecordingPasteboard()
    let saver = ScriptedSaver()

    final class Counter { var count = 0 }

    static let meetingKey = Fixtures.key("meetings", "orchard")
    static let otherKey = Fixtures.key("meetings", "call")
    static let dictationKey = Fixtures.key("dictation", "store/7")

    init(writing: Bool = false) {
        let now = Fixtures.epoch
        meetings = ScriptedNoteSource(
            "meetings",
            items: [
                NoteSummary(
                    id: Self.meetingKey, kind: .meeting, title: "Orchard weekly sync",
                    startedAt: now.addingTimeInterval(-3600), durationMs: 2_520_000, sourceApp: "Zoom"),
                NoteSummary(
                    id: Self.otherKey, kind: .meeting, title: "Customer call",
                    startedAt: now.addingTimeInterval(-86_400 - 3600),
                    state: writing ? .writing(done: 2, of: 5) : .interrupted),
            ])
        dictation = ScriptedNoteSource(
            "dictation",
            items: [
                NoteSummary(
                    id: Self.dictationKey, kind: .dictation, title: "Hi Kasia",
                    startedAt: now.addingTimeInterval(-7200),
                    durationMs: 18_000)
            ])
        meetings.contents[Self.meetingKey] = NoteContent(
            summary: meetings.items[0],
            layers: [
                NoteLayer(id: "notes", author: .agent, markdown: "## Summary\n\nShip it.", version: "1"),
                NoteLayer(id: "transcript", author: .stt, markdown: "Agreed.", version: "1"),
            ], speakers: [NoteSpeaker(id: "1", name: "Kasia")], details: [])
        let box = SourceBox([meetings, dictation])
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        sourceSet = continuation
        let library = NoteLibrary(box: box)
        let counter = settingsOpened
        model = NotesWorkspaceModel(
            environment: NotesWorkspaceModel.Environment(
                library: library, pasteboard: pasteboard, saver: saver, sourceSetChanges: { stream },
                openSettings: { counter.count += 1 },
                now: { now }, calendar: utc, locale: english))
    }
}

@MainActor
@Suite("Notes workspace: listing, tabs and routes")
struct NotesWorkspaceModelTests {
    @Test("the first read lists every source's notes newest first, grouped by time")
    func listing() async {
        let rig = Rig()
        #expect(rig.model.loadState == .loading)
        await rig.model.refresh()
        #expect(rig.model.loadState == .loaded)
        #expect(rig.model.rows.map(\.id.key.rawValue) == ["meetings:orchard", "dictation:store/7", "meetings:call"])
        #expect(rig.model.groups.map { rig.model.title(of: $0) } == ["Today", "Yesterday"])
        #expect(rig.model.total == 3)
    }

    @Test("grouping by source follows the plugins")
    func bySource() async {
        let rig = Rig()
        await rig.model.refresh()
        rig.model.grouping = .source
        #expect(rig.model.groups.map { rig.model.title(of: $0) } == ["Meetings", "Dictation"])
    }

    @Test("a route selects the key and opens one tab for the note")
    func routeOpensOneTab() async {
        let rig = Rig()
        await rig.model.refresh()
        let route = NoteRoute.route(for: Rig.meetingKey)
        #expect(rig.model.handle(route))
        #expect(rig.model.currentID == .live(Rig.meetingKey))
        #expect(rig.model.tabs.tabs.count == 1)
        #expect(rig.model.tabs.tabs[0].title == "Orchard weekly sync")
        // The same route, and the explorer's click, are the same tab.
        #expect(rig.model.handle(route))
        rig.model.open(.live(Rig.meetingKey))
        #expect(rig.model.tabs.tabs.count == 1)
        // Another note is another tab and the route selects it.
        #expect(rig.model.handle(NoteRoute.route(for: Rig.dictationKey)))
        #expect(rig.model.tabs.tabs.count == 2)
        #expect(rig.model.currentID == .live(Rig.dictationKey))
    }

    @Test("a route to a meeting whose tab shows the transcript reuses that tab and its layer")
    func routeReusesTheTranscriptTab() async throws {
        let rig = Rig()
        await rig.model.refresh()
        let id = NoteItemID.live(Rig.meetingKey)
        rig.model.open(id)
        await rig.model.loadContent(id)
        let document = try #require(rig.model.currentDocument)
        document.selectLayer("transcript")
        rig.model.open(.live(Rig.dictationKey))
        #expect(rig.model.currentID != id)
        #expect(rig.model.handle(NoteRoute.route(for: Rig.meetingKey)))
        #expect(rig.model.tabs.tabs.count == 2)
        #expect(rig.model.currentID == id)
        #expect(rig.model.currentDocument === document)
        #expect(document.layerID == "transcript")
    }

    @Test("a route of another kind, or without a note key, is not handled")
    func unhandledRoutes() async {
        let rig = Rig()
        await rig.model.refresh()
        #expect(!rig.model.handle(WorkspaceRoute(kind: "openModels", id: "meetings:orchard")))
        #expect(!rig.model.handle(WorkspaceRoute(kind: "openNote", id: "orchard")))
        #expect(!rig.model.handle(WorkspaceRoute(kind: "openNote", id: ":orchard")))
        #expect(!rig.model.handle(WorkspaceRoute(kind: "openNote", id: "meetings:")))
        #expect(!rig.model.handle(WorkspaceRoute(kind: "openNote", id: "")))
        #expect(rig.model.tabs.tabs.isEmpty)
        #expect(rig.model.currentID == nil)
    }

    @Test("the route id is the key's raw value, also for a dictation key with a slash and a colon")
    func routeRoundTrip() {
        let key = Fixtures.key("dictation", "a:b/9")
        #expect(NoteRoute.itemID(for: NoteRoute.route(for: key)) == .live(key))
        #expect(NoteRoute.route(for: key).kind == "openNote")
    }

    @Test("closing the current tab shows its right neighbour, and the last tab goes with the window")
    func closing() async {
        let rig = Rig()
        await rig.model.refresh()
        let first = NoteItemID.live(Rig.meetingKey)
        let second = NoteItemID.live(Rig.dictationKey)
        let third = NoteItemID.live(Rig.otherKey)
        for id in [first, second, third] { rig.model.open(id) }
        rig.model.select(second)
        #expect(rig.model.closeCurrentTab())
        #expect(rig.model.currentID == third)
        #expect(rig.model.documents[second] == nil)
        #expect(rig.model.closeCurrentTab())
        #expect(rig.model.currentID == first)
        // One tab left: ⌘W closes it and reports that the window should close too.
        #expect(!rig.model.closeCurrentTab())
        #expect(rig.model.currentID == nil)
        #expect(!rig.model.closeCurrentTab())
    }

    @Test("content: an answer is shown, no such note is gone, a failure or a missing source is only unavailable")
    func content() async throws {
        let rig = Rig()
        await rig.model.refresh()
        let id = NoteItemID.live(Rig.meetingKey)
        rig.model.open(id)
        let document = try #require(rig.model.documents[id])
        #expect(document.phase == .loading)
        await rig.model.loadContent(id)
        #expect(document.phase == .loaded)
        #expect(document.layers.map(\.id) == ["notes", "transcript"])
        #expect(document.layerID == "notes")
        // The source stops answering: what was shown stays.
        rig.meetings.contentBehavior = .throwsError
        await rig.model.loadContent(id)
        #expect(document.phase == .loaded)
        // A note the source does not know any more is gone.
        rig.meetings.contentBehavior = .answers
        rig.meetings.contents = [:]
        await rig.model.loadContent(id)
        #expect(document.phase == .gone)
        // A note whose plugin has no source is unavailable, not gone.
        let orphan = NoteItemID.live(Fixtures.key("clipboard", "x"))
        rig.model.open(orphan)
        await rig.model.loadContent(orphan)
        #expect(rig.model.documents[orphan]?.phase == .unavailable)
    }

    @Test("a refresh renames the tab and shows the busy mark while a note is being written")
    func refreshUpdatesTabs() async {
        let rig = Rig(writing: true)
        await rig.model.refresh()
        let id = NoteItemID.live(Rig.otherKey)
        rig.model.open(id)
        #expect(rig.model.tabs.tabs[0].isBusy)
        #expect(rig.model.writingCount == 1)
        #expect(rig.model.statusSummary.hasSuffix("1 writing"))
        rig.meetings.items = [
            NoteSummary(
                id: Rig.otherKey, kind: .meeting, title: "Renamed call",
                startedAt: Fixtures.epoch.addingTimeInterval(-90_000))
        ]
        await rig.model.refresh()
        #expect(rig.model.tabs.tabs[0].title == "Renamed call")
        #expect(!rig.model.tabs.tabs[0].isBusy)
        #expect(rig.model.writingCount == 0)
    }

    @Test("the path bar names the group, the note and a layer past the first")
    func path() async throws {
        let rig = Rig()
        await rig.model.refresh()
        #expect(rig.model.pathComponents == nil)
        let id = NoteItemID.live(Rig.meetingKey)
        rig.model.open(id)
        await rig.model.loadContent(id)
        #expect(rig.model.pathComponents == ["Today", "Orchard weekly sync"])
        try #require(rig.model.currentDocument).selectLayer("transcript")
        #expect(rig.model.pathComponents == ["Today", "Orchard weekly sync", "Transcript"])
    }

    @Test("a dictation's path ends in its kind and time, not its text")
    func dictationPath() async {
        let rig = Rig()
        await rig.model.refresh()
        rig.model.open(.live(Rig.dictationKey))
        let path = rig.model.pathComponents
        #expect(path?.first == "Today")
        #expect(path?.last?.hasPrefix("Dictation") == true)
        #expect(path?.contains("Hi Kasia") == false)
    }

    @Test("a change signalled by the set of sources reads the list again")
    func followsTheSourceSet() async {
        let rig = Rig()
        let running = Task { await rig.model.run() }
        while rig.model.loadState == .loading { await Task.yield() }
        #expect(rig.model.rows.count == 3)
        rig.dictation.items = []
        rig.sourceSet.yield()
        while rig.model.rows.count != 2 { await Task.yield() }
        running.cancel()
        #expect(rig.model.rows.count == 2)
    }

    @Test("the Settings link asks the shell")
    func settingsLink() {
        let rig = Rig()
        rig.model.openSettings()
        #expect(rig.settingsOpened.count == 1)
    }

    // MARK: Copy and save

    private func openMeeting(_ rig: Rig) async {
        await rig.model.refresh()
        let id = NoteItemID.live(Rig.meetingKey)
        rig.model.open(id)
        await rig.model.loadContent(id)
    }

    @Test("Copy Markdown writes the layer on screen and says so")
    func copy() async throws {
        let rig = Rig()
        await openMeeting(rig)
        rig.model.copyMarkdown()
        let write = try #require(rig.pasteboard.writes.first)
        #expect(write.options == [.currentHostOnly])
        let text = write.items.first.flatMap { $0.data(for: PasteboardRepresentation.plainTextType) }
        #expect(text.map { String(decoding: $0, as: UTF8.self) } == "# Orchard weekly sync\n\n## Summary\n\nShip it.\n")
        #expect(rig.model.feedback == .copied)
        let serial = rig.model.feedbackSerial
        rig.model.dismissFeedback()
        #expect(rig.model.feedback == nil)
        #expect(rig.model.feedbackSerial == serial + 1)
        // Nothing is open: nothing is copied.
        rig.model.close(.live(Rig.meetingKey))
        rig.model.copyMarkdown()
        #expect(rig.pasteboard.writes.count == 1)
    }

    @Test("Save .md writes the text under a file name; cancelling says nothing; a failure says so")
    func save() async {
        let rig = Rig()
        await openMeeting(rig)
        await rig.model.saveMarkdown()
        #expect(rig.saver.saved.map(\.name) == ["Orchard weekly sync.md"])
        #expect(rig.saver.saved.first?.text.hasPrefix("# Orchard weekly sync") == true)
        #expect(rig.model.feedback == .saved)
        rig.saver.answer = .cancelled
        await rig.model.saveMarkdown()
        #expect(rig.model.feedback == nil)
        rig.saver.answer = .fails
        await rig.model.saveMarkdown()
        #expect(rig.model.feedback == .saveFailed)
        // Trying again after the disk is fine clears the error.
        rig.saver.answer = .saved
        await rig.model.saveMarkdown()
        #expect(rig.model.feedback == .saved)
    }

    @Test("the transcript is what is copied once it is shown")
    func copyTranscript() async throws {
        let rig = Rig()
        await openMeeting(rig)
        try #require(rig.model.currentDocument).selectLayer("transcript")
        rig.model.copyMarkdown()
        let data = rig.pasteboard.writes.first?.items.first?.data(for: PasteboardRepresentation.plainTextType)
        #expect(String(decoding: data ?? Data(), as: UTF8.self).contains("Agreed."))
    }
}
